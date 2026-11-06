import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import Login from './Login.svelte';
import { createAuthApi } from '$lib/api/auth';
import type { PasskeyOutcome } from '$lib/api/webauthn';
import { t } from '$lib/i18n';

type Handler = (url: string, init: RequestInit) => Response | Promise<Response>;

function api(handler: Handler) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({ url, init });
    return handler(url, init);
  }) as unknown as typeof fetch;
  return { api: createAuthApi({ baseUrl: '/b', fetchImpl }), calls };
}
const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...headers },
  });
const state = (s: string) => ({
  state: s,
  csrfToken: 'csrf-' + s,
  expiresAt: '2026-10-31T10:00:00Z',
});
const okAssertion = async (): Promise<PasskeyOutcome> => ({
  ok: true,
  body: {
    challengeId: 'c1',
    credential: {
      id: 'a',
      rawId: 'a',
      type: 'public-key',
      response: { authenticatorData: 'x', clientDataJSON: 'y', signature: 'z' },
    },
  },
});

describe('Login', () => {
  it('offers TOTP only when the server enables the public path and sends password and code', async () => {
    const { api: a, calls } = api((url) => {
      if (url.endsWith('/auth/session')) return json({ ...state('anonymous'), totpAllowed: true });
      if (url.endsWith('/auth/totp')) return json(state('authenticated'));
      return json({}, 404);
    });
    render(Login, { api: a });
    await screen.findByText(t.accountsPackage.login, { selector: 'summary' });
    await fireEvent.input(screen.getByLabelText(t.accountsPackage.username), {
      target: { value: 'synthetic-user' },
    });
    await fireEvent.input(screen.getByLabelText(t.accountsPackage.password), {
      target: { value: 'synthetic-password' },
    });
    await fireEvent.input(screen.getByLabelText(t.accountsPackage.code), {
      target: { value: '123456' },
    });
    await fireEvent.submit(screen.getByLabelText(t.accountsPackage.code).closest('form')!);
    expect(await screen.findByText(t.login.done)).toBeTruthy();
    const call = calls.find((c) => c.url.endsWith('/auth/totp'))!;
    expect(JSON.parse(call.init.body as string)).toEqual({
      username: 'synthetic-user',
      password: 'synthetic-password',
      code: '123456',
    });
    expect(new Headers(call.init.headers).get('X-CSRF-Token')).toBe('csrf-anonymous');
  });

  it('completes internal login after UV passkey without any password request', async () => {
    const { api: a, calls } = api((url) => {
      if (url.endsWith('/auth/session'))
        return json({ ...state('anonymous'), secondFactorRequired: false });
      if (url.endsWith('/passkey/options')) return json({});
      if (url.endsWith('/passkey/verify'))
        return json({ ...state('authenticated'), secondFactorRequired: false });
      return json({}, 404);
    });
    render(Login, { api: a, assertion: okAssertion });
    await fireEvent.click(await screen.findByRole('button', { name: t.login.passkeyButton }));
    expect(await screen.findByText(t.login.done)).toBeTruthy();
    expect(screen.queryByLabelText(t.login.password)).toBeNull();
    expect(calls.some((c) => c.url.endsWith('/second-factor/password'))).toBe(false);
  });

  it('renders German heading and starts in the passkey step', async () => {
    const { api: a } = api(() => json(state('anonymous')));
    render(Login, { api: a });
    expect(screen.getByRole('heading', { name: t.login.title })).toBeTruthy();
    expect(await screen.findByRole('button', { name: t.login.passkeyButton })).toBeTruthy();
  });

  it('runs passkey then password, sending the CSRF token of the latest session', async () => {
    const { api: a, calls } = api((url) => {
      if (url.endsWith('/auth/session')) return json(state('anonymous'));
      if (url.endsWith('/passkey/options'))
        return json({
          challengeId: 'c1',
          publicKey: {
            challenge: 'AA',
            rpId: 'x',
            timeout: 1,
            userVerification: 'required',
            allowCredentials: [],
          },
          expiresAt: 'e',
        });
      if (url.endsWith('/passkey/verify')) return json(state('factor_pending'));
      if (url.endsWith('/second-factor/password')) return json(state('authenticated'));
      return json({}, 404);
    });
    render(Login, { api: a, assertion: okAssertion });
    await fireEvent.click(await screen.findByRole('button', { name: t.login.passkeyButton }));
    const pw = await screen.findByLabelText(t.login.password);
    expect(
      (
        calls.find((c) => c.url.endsWith('/passkey/options'))!.init.headers as Record<
          string,
          string
        >
      )['X-CSRF-Token'],
    ).toBe('csrf-anonymous');
    await fireEvent.input(pw, { target: { value: 'secret' } });
    await fireEvent.click(screen.getByRole('button', { name: t.login.submit }));
    expect(await screen.findByText(t.login.done)).toBeTruthy();
    const last = calls[calls.length - 1]!;
    expect((last.init.headers as Record<string, string>)['X-CSRF-Token']).toBe(
      'csrf-factor_pending',
    );
    expect(JSON.parse(String(last.init.body))).toEqual({ method: 'password', password: 'secret' });
    expect(last.init.credentials).toBe('same-origin');
  });

  it('shows a uniform failure for a rejected assertion and a countdown for rate limiting', async () => {
    let verify = 0;
    const { api: a } = api((url) => {
      if (url.endsWith('/auth/session')) return json(state('anonymous'));
      if (url.endsWith('/passkey/options'))
        return json({
          challengeId: 'c1',
          publicKey: {
            challenge: 'AA',
            rpId: 'x',
            timeout: 1,
            userVerification: 'required',
            allowCredentials: [],
          },
          expiresAt: 'e',
        });
      verify++;
      return verify === 1
        ? json({ code: 'authentication_failed' }, 401)
        : json({ code: 'rate_limited' }, 429, { 'Retry-After': '42' });
    });
    render(Login, { api: a, assertion: okAssertion });
    await fireEvent.click(await screen.findByRole('button', { name: t.login.passkeyButton }));
    expect((await screen.findByRole('alert')).textContent).toBe(t.login.failed);
    await fireEvent.click(screen.getByRole('button', { name: t.login.passkeyButton }));
    await waitFor(() => expect(screen.getByRole('alert').textContent).toContain('42'));
  });

  it('maps authenticator outcomes and server outage to messages, and can retry', async () => {
    let up = false;
    const { api: a } = api(() => (up ? json(state('anonymous')) : json({}, 503)));
    const { unmount } = render(Login, { api: a });
    expect((await screen.findByRole('alert')).textContent).toBe(t.login.unavailable);
    up = true;
    await fireEvent.click(screen.getByRole('button', { name: t.login.retry }));
    expect(await screen.findByRole('button', { name: t.login.passkeyButton })).toBeTruthy();
    unmount();

    const cancel = vi.fn(async (): Promise<PasskeyOutcome> => ({ ok: false, reason: 'cancelled' }));
    const { api: b } = api((url) =>
      url.endsWith('/auth/session')
        ? json(state('anonymous'))
        : json({
            challengeId: 'c',
            publicKey: {
              challenge: 'AA',
              rpId: 'x',
              timeout: 1,
              userVerification: 'required',
              allowCredentials: [],
            },
            expiresAt: 'e',
          }),
    );
    render(Login, { api: b, assertion: cancel });
    await fireEvent.click(await screen.findByRole('button', { name: t.login.passkeyButton }));
    expect((await screen.findByRole('alert')).textContent).toBe(t.login.cancelled);
  });

  it('resumes the right step from an existing session and logs out', async () => {
    let state_ = 'authenticated';
    const { api: a, calls } = api((url) => {
      if (url.endsWith('/logout')) {
        state_ = 'anonymous';
        return new Response(null, { status: 204 });
      }
      return json(state(state_));
    });
    render(Login, { api: a });
    await fireEvent.click(await screen.findByRole('button', { name: t.login.logout }));
    expect(await screen.findByRole('button', { name: t.login.passkeyButton })).toBeTruthy();
    expect(calls.some((c) => c.url.endsWith('/logout') && c.init.method === 'POST')).toBe(true);
  });
});
