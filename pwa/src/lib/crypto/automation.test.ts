// @vitest-environment node
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import fixture from './fixtures/rotation.json';
const api = vi.hoisted(() => ({
  rotation: vi.fn(),
  rotationObjects: vi.fn(),
  rewrapObject: vi.fn(),
  finishRotation: vi.fn(),
  customerKey: vi.fn(),
  setCustomerKeyWithAccess: vi.fn(),
  keyBundle: vi.fn(),
  putAccountKey: vi.fn(),
  saveAccountRecovery: vi.fn(),
}));
vi.mock('$lib/api', () => ({ adminApi: api }));
import { accessAutomation as worker } from './automation.svelte';
import { keyring } from './keyring.svelte';
import { identity, openPackage, toBase64Url } from './packageV2';
import { LOGIN_PRF_SALT } from '$lib/api/webauthn';
import { grantAccess, wrapAccountKey } from './keys';
const hex = (s: string) => Uint8Array.from(s.match(/../g)!, (x) => parseInt(x, 16));
const oldKid = 'd19bf3f082782c87',
  newKid = '427ff2bd08c0c694';
beforeEach(() => {
  vi.resetAllMocks();
  keyring.lock();
  worker.stop();
});
afterEach(() => {
  worker.stop();
  keyring.lock();
});

it('setzt eine Warteschlange nach CAS-Konflikt fort; Hold bleibt sym und der Nutzinhalt identisch', async () => {
  keyring.unlocked = true;
  keyring.adopt(oldKid, hex(fixture.oldSecret));
  keyring.adopt(newKid, hex(fixture.newSecret));
  api.rotation.mockResolvedValue({
    ok: true,
    data: {
      active: { kid: newKid, publicKey: toBase64Url(hex(fixture.newPublicKey)) },
      retiring: { kid: oldKid },
    },
  });
  api.rotationObjects.mockResolvedValue({
    ok: true,
    data: {
      items: [
        {
          id: 'object',
          package: fixture.cases[0]!.source,
          held: true,
          wrapKind: 'hpke',
          revision: 9,
          ciphertext_sha256: 'digest',
        },
      ],
      next: null,
    },
  });
  api.rewrapObject.mockResolvedValueOnce({ ok: false }).mockResolvedValue({ ok: true });
  api.finishRotation.mockResolvedValue({ ok: true });
  worker.start(['tenant']);
  await vi.waitFor(() => expect(worker.busy).toBe(false));
  expect(api.finishRotation).not.toHaveBeenCalled();
  expect(worker.message).toBeTruthy();
  await worker.run();
  const body = api.rewrapObject.mock.calls[1]![2];
  expect(body.expectedRevision).toBe(9);
  expect(body.package.split('|')[2]).toBe('sym');
  expect(body.package.split('|').slice(4)).toEqual(fixture.cases[0]!.source.split('|').slice(4));
  expect(await openPackage(body.package, hex(fixture.newSecret))).toEqual(
    hex(fixture.cases[0]!.plaintext),
  );
  expect(api.finishRotation).toHaveBeenCalledWith('tenant', oldKid);
  expect(keyring.dataKey(oldKid)).toBeUndefined();
});

it('Sperren während des Inventarabrufs verhindert Ersatzversand und Abschluss', async () => {
  keyring.unlocked = true;
  keyring.adopt(oldKid, hex(fixture.oldSecret));
  keyring.adopt(newKid, hex(fixture.newSecret));
  api.rotation.mockResolvedValue({
    ok: true,
    data: { active: { kid: newKid }, retiring: { kid: oldKid } },
  });
  let release!: (v: unknown) => void;
  api.rotationObjects.mockImplementation(() => new Promise((r) => (release = r)));
  worker.start(['tenant']);
  await vi.waitFor(() => expect(release).toBeDefined());
  keyring.lock();
  release({ ok: true, data: { items: [], next: null } });
  await vi.waitFor(() => expect(worker.busy).toBe(false));
  expect(api.rewrapObject).not.toHaveBeenCalled();
  expect(api.finishRotation).not.toHaveBeenCalled();
});

it('öffnet Login-PRF und echte Zugangshülle ohne zweite Passkey-Abfrage, löscht die PRF-Ausgabe', async () => {
  const secret = hex(fixture.oldSecret),
    account = await identity(secret);
  const prf = { credentialId: new Uint8Array([1]), output: new Uint8Array(32).fill(7) };
  const wrap = await wrapAccountKey(secret, prf.output, prf.credentialId);
  const access = await grantAccess(hex(fixture.newSecret), account.publicKey, newKid);
  api.keyBundle.mockResolvedValue({
    ok: true,
    data: {
      rpId: 'example.test',
      accountPublicKey: toBase64Url(account.publicKey),
      wraps: [
        {
          credentialId: 'AQ',
          prfSalt: toBase64Url(LOGIN_PRF_SALT),
          iv: toBase64Url(wrap.iv),
          wrap: toBase64Url(wrap.wrap),
        },
      ],
      access: [
        {
          tenantId: 'tenant',
          kid: newKid,
          enc: toBase64Url(access.enc),
          sealed: toBase64Url(access.sealed),
        },
      ],
    },
  });
  expect(await keyring.afterLogin(prf)).toBeNull();
  expect(keyring.unlocked).toBe(true);
  expect(keyring.dataKey(newKid)).toEqual(hex(fixture.newSecret));
  expect(prf.output.every((x) => x === 0)).toBe(true);
});

it('Einrichtung speichert ausschließlich Hüllen; Wiederholung erzeugt keine zweite Generation', async () => {
  api.keyBundle.mockResolvedValue({
    ok: true,
    data: { accountPublicKey: null, rpId: 'example.test' },
  });
  api.putAccountKey.mockResolvedValue({ ok: true });
  expect(
    await keyring.afterLogin({
      credentialId: new Uint8Array([1]),
      output: new Uint8Array(32).fill(9),
    }),
  ).toBeNull();
  expect(await keyring.prepareRecovery()).toBeNull();
  const accountCode = keyring.recoveryCode;
  api.saveAccountRecovery.mockResolvedValue({ ok: true, data: { revision: 'r1' } });
  expect(await keyring.confirmRecovery(accountCode)).toBeNull();
  api.customerKey
    .mockResolvedValueOnce({ ok: false, error: { status: 404 } })
    .mockResolvedValue({ ok: true });
  api.setCustomerKeyWithAccess.mockResolvedValue({ ok: true });
  await worker.ensureCustomer('tenant');
  await worker.ensureCustomer('tenant');
  expect(api.setCustomerKeyWithAccess).toHaveBeenCalledTimes(1);
  const body = api.setCustomerKeyWithAccess.mock.calls[0]![1];
  expect(Object.keys(body).sort()).toEqual(['access', 'publicKey', 'recovery']);
  expect(keyring.pendingCode).toBe('');
  expect(JSON.stringify(body)).not.toContain(accountCode);
});

it('Hintergrundprüfungen verlängern die Inaktivitätsfrist nicht', async () => {
  vi.useFakeTimers();
  try {
    keyring.unlocked = true;
    keyring.adopt(oldKid, hex(fixture.oldSecret));
    api.rotation.mockResolvedValue({ ok: true, data: { active: { kid: oldKid }, retiring: null } });
    worker.start(['tenant']);
    await vi.advanceTimersByTimeAsync(610_000);
    expect(keyring.unlocked).toBe(false);
    expect(keyring.kids).toEqual([]);
  } finally {
    vi.useRealTimers();
  }
});

it('beginnt dauerhaften Rotationsbedarf automatisch und führt den wiederaufgenommenen Bestand seriell fort', async () => {
  keyring.unlocked = true;
  keyring.adopt(oldKid, hex(fixture.oldSecret));
  keyring.adopt(newKid, hex(fixture.newSecret));
  const refresh = vi.spyOn(keyring, 'refreshAccess').mockResolvedValue();
  const begin = vi.spyOn(keyring, 'rotateAutomatic').mockResolvedValue(true);
  const repair = vi.spyOn(keyring, 'repairAutomatic').mockResolvedValue('ok');
  api.rotation
    .mockResolvedValueOnce({
      ok: true,
      data: { requested: true, active: { kid: oldKid }, retiring: null },
    })
    .mockResolvedValue({
      ok: true,
      data: { requested: false, active: { kid: newKid }, retiring: { kid: oldKid } },
    });
  api.rotationObjects.mockResolvedValue({ ok: true, data: { items: [], next: null } });
  api.finishRotation.mockResolvedValue({ ok: true });
  worker.start(['tenant']);
  await vi.waitFor(() => expect(api.finishRotation).toHaveBeenCalledOnce());
  expect(begin).toHaveBeenCalledWith('tenant', oldKid);
  expect(refresh).toHaveBeenCalledOnce();
  begin.mockRestore();
  refresh.mockRestore();
  repair.mockRestore();
});

it('importierte Generation ohne Zugang: benennt die Ursache, wiederholt die Reparatur nicht und fragt nie nach dem Passkey', async () => {
  keyring.unlocked = true;
  api.rotation.mockResolvedValue({
    ok: true,
    data: { active: { kid: newKid, publicKey: 'x' }, retiring: { kid: oldKid } },
  });
  const refresh = vi.spyOn(keyring, 'refreshAccess').mockResolvedValue();
  const repair = vi.spyOn(keyring, 'repairAutomatic').mockResolvedValue('missing');
  worker.start(['tenant']);
  await vi.waitFor(() => expect(worker.busy).toBe(false));
  expect(worker.message).toContain('fehlt Ihr Zugang');
  expect(repair).toHaveBeenCalledTimes(1);
  await worker.run();
  await worker.run();
  expect(repair).toHaveBeenCalledTimes(1); // no repeated recovery reads (they are audited) every 30 seconds
  expect(api.rewrapObject).not.toHaveBeenCalled();
  // after the next lock the question is asked again
  keyring.lock();
  keyring.unlocked = true;
  await worker.run();
  expect(repair).toHaveBeenCalledTimes(2);
  repair.mockResolvedValue('reauth');
  keyring.lock();
  keyring.unlocked = true;
  await worker.run();
  expect(worker.message).toContain('Passkey-Bestätigung');
  refresh.mockRestore();
  repair.mockRestore();
});

it('gesperrter Schlüsselbund (Konto hat Schlüssel): Entsperr-Hinweis statt einrichten', async () => {
  api.customerKey.mockResolvedValue({ ok: false, error: { status: 404 } });
  api.keyBundle.mockResolvedValue({
    ok: true,
    data: { accountPublicKey: 'pk', recovery: { revision: 'r' }, rpId: 'example.test' },
  });
  const error = await worker.ensureCustomer('tenant').catch((e: Error) => e);
  expect((error as Error).message).toMatch(/gesperrt/);
  expect((error as Error).message).toMatch(/Konto/);
  expect((error as Error).message).not.toMatch(/einrichten/);
});

it('nie eingerichtet (kein Kontoschlüssel): weiterhin einrichten', async () => {
  api.customerKey.mockResolvedValue({ ok: false, error: { status: 404 } });
  api.keyBundle.mockResolvedValue({
    ok: true,
    data: { accountPublicKey: null, recovery: null, rpId: 'example.test' },
  });
  const error = await worker.ensureCustomer('tenant').catch((e: Error) => e);
  expect((error as Error).message).toMatch(/einrichten/);
});
