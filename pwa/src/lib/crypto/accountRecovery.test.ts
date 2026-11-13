// @vitest-environment node
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import type { KeyBundle } from '$lib/api/admin';
const api = vi.hoisted(() => ({
  keyBundle: vi.fn(),
  saveAccountRecovery: vi.fn(),
  setCustomerKeyWithAccess: vi.fn(),
  keyCandidates: vi.fn(),
  beginRotation: vi.fn(),
  keyRecovery: vi.fn(),
  grantKeyAccess: vi.fn(),
}));
vi.mock('$lib/api', () => ({ adminApi: api }));
vi.mock('$lib/api/webauthn', async (original) => ({
  ...(await original<typeof import('$lib/api/webauthn')>()),
  requestPrf: async () => null,
}));
import { keyring } from './keyring.svelte';
import { generateKeyPair, grantAccess, openAccess, openAccountRecovery } from './keys';
import { fromBase64Url, toBase64Url } from './packageV2';
let bundle: KeyBundle;
beforeEach(() => {
  vi.resetAllMocks();
  keyring.bind('self', 'session');
  keyring.lock();
  bundle = { rpId: 'example.test', accountPublicKey: null, wraps: [], access: [], recovery: null };
  api.keyBundle.mockImplementation(async () => ({ ok: true, data: bundle }));
  api.saveAccountRecovery.mockImplementation(async (publicKey, expected, recovery) => {
    if ((bundle.recovery?.revision ?? null) !== expected) return { ok: false };
    bundle = {
      ...bundle,
      accountPublicKey: publicKey,
      recovery: { ...recovery, revision: crypto.randomUUID() },
    };
    return { ok: true, data: { revision: bundle.recovery!.revision } };
  });
});
afterEach(() => keyring.lock());
async function setup() {
  expect(await keyring.prepareRecovery()).toBeNull();
  const code = keyring.recoveryCode;
  expect(await keyring.confirmRecovery(code)).toBeNull();
  return code;
}
it('richtet ohne PRF erst nach Bestätigung ein und öffnet nach erneutem Login echte HPKE-Zugänge', async () => {
  expect(await keyring.prepareRecovery()).toBeNull();
  const code = keyring.recoveryCode;
  expect(await keyring.confirmRecovery('falsch')).toBe('mismatch');
  expect(api.saveAccountRecovery).not.toHaveBeenCalled();
  expect(await keyring.confirmRecovery(code)).toBeNull();
  expect(keyring.recoveryCode).toBe('');
  expect(JSON.stringify(api.saveAccountRecovery.mock.calls)).not.toContain(code);
  const data = await generateKeyPair();
  const access = await grantAccess(data.secret, fromBase64Url(bundle.accountPublicKey!), data.kid);
  bundle.access = [
    {
      tenantId: 't',
      kid: data.kid,
      enc: toBase64Url(access.enc),
      sealed: toBase64Url(access.sealed),
    },
  ];
  keyring.lock();
  expect(await keyring.recoverAccount('X'.repeat(32))).toBe('mismatch');
  expect(keyring.unlocked).toBe(false);
  expect(await keyring.recoverAccount(code)).toBeNull();
  expect(keyring.dataKey(data.kid)).toEqual(data.secret);
});
it('prüft Codes ohne zu entsperren; Erneuerung erhält dieselbe Kontoidentität und entwertet den alten Code', async () => {
  const old = await setup();
  const publicKey = bundle.accountPublicKey;
  expect(await keyring.recoverAccount(old, true)).toBeNull();
  expect(await keyring.prepareRecovery()).toBeNull();
  const next = keyring.recoveryCode;
  expect(await keyring.recoverAccount(old, true)).toBeNull(); // not replaced before confirmation
  expect(await keyring.confirmRecovery(next)).toBeNull();
  expect(bundle.accountPublicKey).toBe(publicKey);
  keyring.lock();
  expect(await keyring.recoverAccount(old)).toBe('mismatch');
  expect(await keyring.recoverAccount(next, true)).toBeNull();
  expect(keyring.unlocked).toBe(false);
});
it('verhindert Überschreiben bei CAS-Konflikt und erhält den noch gültigen Code', async () => {
  const old = await setup();
  await keyring.prepareRecovery();
  bundle.recovery!.revision = 'another-tab';
  expect(await keyring.confirmRecovery(keyring.recoveryCode)).toBe('server');
  expect(await keyring.recoverAccount(old, true)).toBeNull();
});
it('verwirft eine unbestätigte Einrichtung bei Sperre ohne Servermutation', async () => {
  await keyring.prepareRecovery();
  const code = keyring.recoveryCode;
  keyring.lock();
  expect(await keyring.confirmRecovery(code)).toBe('mismatch');
  expect(bundle.accountPublicKey).toBeNull();
});
it('entsperrt nach Sperre während eines Requests nicht nachträglich', async () => {
  await setup();
  await keyring.prepareRecovery();
  api.saveAccountRecovery.mockImplementation(async () => {
    keyring.lock();
    return { ok: true, data: { revision: 'new' } };
  });
  expect(await keyring.confirmRecovery(keyring.recoveryCode)).toBe('locked');
  expect(keyring.unlocked).toBe(false);
});
it('ersetzt einen vorhandenen gesperrten Kontozugang niemals durch neuen Schutz', async () => {
  await setup();
  keyring.lock();
  expect(await keyring.prepareRecovery()).toBe('locked');
});
it('neue Kunden benötigen keinen weiteren Alltagscode und sind nach Kontorecovery entschlüsselbar', async () => {
  const code = await setup();
  api.setCustomerKeyWithAccess.mockResolvedValue({ ok: true });
  const result = await keyring.createCustomerKey('t');
  expect(typeof result).toBe('object');
  expect(keyring.pendingCode).toBe('');
  const request = api.setCustomerKeyWithAccess.mock.calls[0]![1];
  const r = bundle.recovery!;
  const secret = await openAccountRecovery(
    {
      salt: fromBase64Url(r.salt),
      iterations: r.iterations,
      iv: fromBase64Url(r.iv),
      wrap: fromBase64Url(r.wrap),
    },
    code,
    bundle.accountPublicKey!,
  );
  if (typeof result === 'string') throw Error();
  expect(
    await openAccess(
      fromBase64Url(request.access.enc),
      fromBase64Url(request.access.sealed),
      secret,
      result.kid,
    ),
  ).toEqual(keyring.dataKey(result.kid));
  secret.fill(0);
});
it('automatische Rotation überträgt nur bereits bestätigte Empfänger und benötigt keinen neuen Code', async () => {
  await setup();
  const data = await generateKeyPair();
  keyring.adopt(data.kid, data.secret);
  const recipient = await generateKeyPair();
  api.keyCandidates.mockResolvedValue({
    ok: true,
    data: {
      items: [
        { accountId: 'approved', publicKey: toBase64Url(recipient.publicKey), hasAccess: true },
        { accountId: 'unapproved', publicKey: toBase64Url(recipient.publicKey), hasAccess: false },
      ],
    },
  });
  api.beginRotation.mockResolvedValue({ ok: true });
  expect(await keyring.rotateAutomatic('t', data.kid)).toBe(true);
  const body = api.beginRotation.mock.calls[0]![1];
  expect(body.access.map((a: { accountId: string }) => a.accountId)).toEqual(['self', 'approved']);
  expect(keyring.pendingCode).toBe('');
});

it('fehlendes PRF öffnet weder neue noch bestehende Konten und verlangt ausdrücklich Recovery', async () => {
  expect(await keyring.afterLogin()).toBe('unsupported');
  expect(keyring.recoveryRequired).toBe(true);
  expect(keyring.unlocked).toBe(false);
  const code = await setup();
  keyring.lock();
  // the account key exists, but no passkey can open it: the message must point to the recovery code, not to a missing key
  expect(await keyring.afterLogin()).toBe('no-passkey');
  expect(keyring.unlocked).toBe(false);
  expect(await keyring.recoverAccount(code)).toBeNull();
});
it('verwirft manipulierte Hüllen und unbekannte KDF-Parameter', async () => {
  const code = await setup();
  keyring.lock();
  bundle.recovery!.iterations = 1;
  expect(await keyring.recoverAccount(code)).toBe('mismatch');
  bundle.recovery!.iterations = 600000;
  bundle.recovery!.wrap = toBase64Url(new Uint8Array(48));
  expect(await keyring.recoverAccount(code)).toBe('mismatch');
  expect(keyring.unlocked).toBe(false);
});

it('repariert einen fehlenden Eigenzugang aus der abgeleiteten Recovery ohne Alltagsdialog', async () => {
  const code = await setup();
  api.setCustomerKeyWithAccess.mockResolvedValue({ ok: true });
  const created = await keyring.createCustomerKey('t');
  if (typeof created === 'string') throw Error(created);
  const secret = keyring.dataKey(created.kid)!.slice();
  const body = api.setCustomerKeyWithAccess.mock.calls[0]![1];
  keyring.lock();
  expect(await keyring.recoverAccount(code)).toBeNull();
  api.keyRecovery.mockResolvedValue({ ok: true, data: { keyId: created.kid, ...body.recovery } });
  api.grantKeyAccess.mockResolvedValue({ ok: true });
  expect(await keyring.repairAutomatic('t', created.kid)).toBe('ok');
  expect(keyring.dataKey(created.kid)).toEqual(secret);
  expect(api.grantKeyAccess).toHaveBeenCalledWith(
    't',
    'self',
    expect.objectContaining({ kid: created.kid }),
    true, // background repair: never opens the passkey dialog
  );
  expect(api.keyRecovery).toHaveBeenCalledWith('t', created.kid, true);
});

it('benennt die Ursache beim Öffnen mit dem Recovery-Code', async () => {
  const code = await setup();
  const http = (status: number, errorCode?: string) => ({
    ok: false,
    error: { kind: 'http', status, ...(errorCode ? { code: errorCode } : {}), message: 'x' },
  });
  // authorised, but the generation has no recovery wrap (migration left none)
  api.keyRecovery.mockResolvedValue(http(404, 'recovery_missing'));
  expect(await keyring.recover('t', code, '0123456789abcdef')).toBe('no-recovery');
  // no right (plain 404) stays a generic failure: the cause must not be guessed
  api.keyRecovery.mockResolvedValue(http(404));
  expect(await keyring.recover('t', code, '0123456789abcdef')).toBe('server');
  // fresh confirmation demanded and not given
  api.keyRecovery.mockResolvedValue(http(403, 'reauthentication_required'));
  expect(await keyring.recover('t', code, '0123456789abcdef')).toBe('reauth');
  // wrap of the expected kid, but the wrong code
  const data = await generateKeyPair();
  const wrapped = await (await import('./keys')).wrapRecovery(data.secret, code, data.kid);
  api.keyRecovery.mockResolvedValue({
    ok: true,
    data: {
      keyId: data.kid,
      salt: toBase64Url(wrapped.salt),
      iterations: wrapped.iterations,
      iv: toBase64Url(wrapped.iv),
      wrap: toBase64Url(wrapped.wrap),
    },
  });
  expect(await keyring.recover('t', 'AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH', data.kid)).toBe(
    'wrong-code',
  );
  // normalisation: lower case and blanks instead of hyphens open it
  expect(await keyring.recover('t', code.toLowerCase().replace(/-/g, ' '), data.kid)).toBeNull();
});
