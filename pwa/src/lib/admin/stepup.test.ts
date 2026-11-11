import { afterEach, describe, expect, it, vi } from 'vitest';
import { createStepUp, type StepUpDeps } from './stepup.svelte';
import { createHttp, setReauthHandler } from '$lib/api/http';
import type { ApiResult } from '$lib/api/client';
import type { PasskeyOptions, PasskeyOutcome } from '$lib/api/webauthn';

const options: PasskeyOptions = {
  challengeId: 'c1',
  publicKey: {
    challenge: 'AAAA',
    rpId: 'localhost',
    timeout: 120000,
    userVerification: 'required',
    allowCredentials: [{ type: 'public-key', id: 'AQID' }],
  },
  expiresAt: 'x',
};
const assertionOk: PasskeyOutcome = {
  ok: true,
  body: {
    challengeId: 'c1',
    credential: {
      id: 'AQID',
      rawId: 'AQID',
      type: 'public-key',
      response: { authenticatorData: 'AQ', clientDataJSON: 'Ag', signature: 'Aw' },
    },
  },
};
const httpError = (status: number, code?: string): ApiResult<never> => ({
  ok: false,
  error: { kind: 'http', status, message: 'x', ...(code ? { code } : {}) },
});

function setup(over: Partial<StepUpDeps> = {}) {
  let userAction: (() => void) | undefined;
  const deps = {
    options: vi.fn(async (): Promise<ApiResult<PasskeyOptions>> => ({ ok: true, data: options })),
    verify: vi.fn(async (): Promise<ApiResult<unknown>> => ({
      ok: true,
      data: { status: 'fresh' },
    })),
    assertion: vi.fn(async (): Promise<PasskeyOutcome> => assertionOk),
    supported: () => true,
    onUserAction: (cb: () => void) => {
      userAction = cb;
      return () => (userAction = undefined);
    },
    ...over,
  };
  const stepUp = createStepUp(deps);
  return { stepUp, deps, act: () => userAction?.() };
}

afterEach(() => setReauthHandler(undefined));

describe('Passkey-Bestätigung auf der Seite (Step-up)', () => {
  it('teilt einen Dialog für gleichzeitige Anfragen und bestätigt alle gemeinsam', async () => {
    const { stepUp, deps } = setup();
    const a = stepUp.request();
    const b = stepUp.request();
    expect(stepUp.open).toBe(true);
    await stepUp.confirm();
    expect(await a).toBe('confirmed');
    expect(await b).toBe('confirmed');
    expect(deps.options).toHaveBeenCalledTimes(1);
    expect(deps.verify).toHaveBeenCalledWith(assertionOk.ok ? assertionOk.body : undefined);
    expect(stepUp.open).toBe(false);
  });

  it('öffnet nach „Abbrechen“ erst nach der nächsten Nutzeraktion wieder (kein Dialog-Spam)', async () => {
    const { stepUp, act } = setup();
    const first = stepUp.request();
    stepUp.cancel();
    expect(await first).toBe('cancelled');
    expect(stepUp.suppressed).toBe(true);
    // background polling: answered at once, no dialog
    expect(await stepUp.request()).toBe('cancelled');
    expect(stepUp.open).toBe(false);
    act();
    expect(stepUp.suppressed).toBe(false);
    void stepUp.request();
    expect(stepUp.open).toBe(true);
  });

  it('zeigt bei abgebrochener oder fehlgeschlagener Passkey-Abfrage „Erneut versuchen“ und bestätigt danach', async () => {
    const assertion = vi
      .fn<StepUpDeps['assertion']>()
      .mockResolvedValue(assertionOk)
      .mockResolvedValueOnce({ ok: false, reason: 'cancelled' });
    const verify = vi
      .fn<StepUpDeps['verify']>()
      .mockResolvedValueOnce(httpError(401, 'authentication_failed'));
    const { stepUp } = setup({ assertion, verify });
    const result = stepUp.request();
    await stepUp.confirm();
    expect(stepUp.phase).toBe('error');
    expect(stepUp.error).toBe('cancelled');
    expect(stepUp.open).toBe(true);
    await stepUp.confirm();
    expect(stepUp.error).toBe('failed');
    verify.mockResolvedValueOnce({ ok: true, data: {} });
    await stepUp.confirm();
    expect(await result).toBe('confirmed');
  });

  it('meldet zu viele Versuche ohne Rückfall', async () => {
    const { stepUp } = setup({ verify: async () => httpError(429, 'rate_limited') });
    void stepUp.request();
    await stepUp.confirm();
    expect(stepUp.error).toBe('rateLimited');
    expect(stepUp.open).toBe(true);
  });

  it.each([
    [
      'Server verlangt Zweitfaktor (409)',
      { options: async () => httpError(409, 'second_factor_required') },
    ],
    ['älterer Server ohne Step-up (404)', { options: async () => httpError(404) }],
    [
      'Sitzung weg (401 ohne authentication_failed)',
      { verify: async () => httpError(401, 'unauthorized') },
    ],
    [
      'Browser ohne Passkey-Unterstützung',
      { assertion: async () => ({ ok: false, reason: 'unsupported' }) as PasskeyOutcome },
    ],
  ] as [string, Partial<StepUpDeps>][])(
    'fällt zurück auf die volle Anmeldung: %s',
    async (_, over) => {
      const { stepUp } = setup(over);
      const result = stepUp.request();
      await stepUp.confirm();
      expect(await result).toBe('fallback');
      expect(stepUp.open).toBe(false);
    },
  );

  it('fällt ohne WebAuthn im Browser sofort zurück, ohne Dialog', async () => {
    const { stepUp } = setup({ supported: () => false });
    expect(await stepUp.request()).toBe('fallback');
    expect(stepUp.open).toBe(false);
  });

  it('eine späte Antwort nach Abbruch verändert keinen neuen Dialog', async () => {
    let release: (v: PasskeyOutcome) => void = () => {};
    const assertion = vi.fn(() => new Promise<PasskeyOutcome>((r) => (release = r)));
    const { stepUp, deps, act } = setup({ assertion });
    void stepUp.request();
    const pending = stepUp.confirm();
    await Promise.resolve();
    stepUp.cancel();
    act();
    void stepUp.request();
    release(assertionOk);
    await pending;
    expect(deps.verify).not.toHaveBeenCalled();
    expect(stepUp.open).toBe(true);
    expect(stepUp.phase).toBe('ready');
  });

  it('mit dem HTTP-Handler: 403 → Dialog → bestätigt → Aufruf genau einmal wiederholt', async () => {
    const { stepUp } = setup();
    setReauthHandler(async () => (await stepUp.request()) === 'confirmed');
    const reauth = () =>
      new Response(JSON.stringify({ code: 'reauthentication_required' }), {
        status: 403,
        headers: { 'Content-Type': 'application/json' },
      });
    const ok = () =>
      new Response(JSON.stringify({ items: [1] }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(reauth())
      .mockResolvedValueOnce(reauth())
      .mockResolvedValueOnce(ok())
      .mockResolvedValueOnce(ok());
    const http = createHttp({ fetchImpl });
    const both = Promise.all([http.request('GET', '/a'), http.request('POST', '/b')]);
    await vi.waitFor(() => expect(stepUp.open).toBe(true));
    await stepUp.confirm();
    const [a, b] = await both;
    expect(a.ok && b.ok).toBe(true);
    expect(fetchImpl).toHaveBeenCalledTimes(4);
  });
});
