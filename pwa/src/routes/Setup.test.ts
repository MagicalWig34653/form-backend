import { describe, expect, it } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';
import Setup from './Setup.svelte';
import { createAuthApi } from '$lib/api/auth';
import type { RegistrationOutcome } from '$lib/api/webauthn';
import { t } from '$lib/i18n';

type Call = { url: string; body: unknown; headers: Record<string, string> };
function api(handler: (url: string) => Response) {
  const calls: Call[] = [];
  const fetchImpl = (async (url: string, init: RequestInit) => {
    calls.push({
      url,
      body: init.body ? JSON.parse(String(init.body)) : undefined,
      headers: init.headers as Record<string, string>,
    });
    return handler(url);
  }) as unknown as typeof fetch;
  return { api: createAuthApi({ baseUrl: '/b', fetchImpl }), calls };
}
const json = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { 'Content-Type': 'application/json' } });
const opts = {
  challengeId: 'c1',
  publicKey: {
    challenge: 'AA',
    rp: { id: 'x', name: 'x' },
    user: { id: 'AA', name: 'u', displayName: 'u' },
    pubKeyCredParams: [],
    timeout: 1,
    attestation: 'none',
    authenticatorSelection: {},
    excludeCredentials: [],
  },
  expiresAt: 'e',
};
const created: RegistrationOutcome = {
  ok: true,
  body: {
    challengeId: 'c1',
    credential: {
      id: 'a',
      rawId: 'a',
      type: 'public-key',
      response: { attestationObject: 'x', clientDataJSON: 'y' },
    },
  },
};

describe('Setup (passkey enrollment)', () => {
  it('shows an error without a token and removes nothing it does not have', () => {
    render(Setup, { fragment: () => '' });
    expect(screen.getByRole('alert').textContent).toBe(t.setup.missingToken);
    expect(screen.queryByRole('button', { name: t.setup.start })).toBeNull();
  });

  it.each([false, true])(
    'registers with fragment and reports second factor policy %s',
    async (secondFactorRequired) => {
      window.history.replaceState(null, '', '/setup#SECRETTOKEN');
      const { api: a, calls } = api((url) => {
        if (url.endsWith('/auth/session'))
          return json({
            state: 'anonymous',
            csrfToken: 'csrf1',
            expiresAt: 'e',
            secondFactorRequired,
          });
        if (url.endsWith('/enrollment/options')) return json(opts);
        return json({ status: 'registered' });
      });
      render(Setup, { api: a, create: async () => created, fragment: () => '#SECRETTOKEN' });
      expect(window.location.hash).toBe(''); // token removed from the URL
      await fireEvent.input(screen.getByLabelText(t.setup.label), {
        target: { value: ' Laptop ' },
      });
      await fireEvent.click(screen.getByRole('button', { name: t.setup.start }));
      expect(await screen.findByText(t.setup.done)).toBeTruthy();
      expect(Boolean(screen.queryByText(t.setup.passwordRequired))).toBe(secondFactorRequired);
      expect(document.querySelector('input[type=password]')).toBeNull();
      const verify = calls.find((c) => c.url.endsWith('/enrollment/verify'))!;
      expect(verify.body).toMatchObject({
        token: 'SECRETTOKEN',
        label: 'Laptop',
        challengeId: 'c1',
      });
      expect(verify.headers['X-CSRF-Token']).toBe('csrf1');
      expect(screen.queryByText('SECRETTOKEN')).toBeNull();
    },
  );

  it('maps refusals and authenticator outcomes to messages without leaking details', async () => {
    const cases: [RegistrationOutcome | 'server', string][] = [
      [{ ok: false, reason: 'cancelled' }, t.setup.cancelled],
      [{ ok: false, reason: 'unsupported' }, t.setup.unsupported],
      [{ ok: false, reason: 'duplicate' }, t.setup.duplicate],
      ['server', t.setup.failed],
    ];
    for (const [outcome, text] of cases) {
      const { api: a } = api((url) =>
        url.endsWith('/auth/session')
          ? json({ state: 'anonymous', csrfToken: 'c', expiresAt: 'e' })
          : outcome === 'server'
            ? json({ code: 'registration_failed' }, 422)
            : json(opts),
      );
      const { unmount } = render(Setup, {
        api: a,
        create: async () => (outcome === 'server' ? created : outcome),
        fragment: () => '#T',
      });
      await fireEvent.click(screen.getByRole('button', { name: t.setup.start }));
      expect((await screen.findByRole('alert')).textContent).toBe(text);
      unmount();
    }
  });
});
