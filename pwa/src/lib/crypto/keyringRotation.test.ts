// @vitest-environment node
// SPDX-License-Identifier: AGPL-3.0-only
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
const fixture = vi.hoisted(() => ({
  generated: [] as Uint8Array[],
  recovery: undefined as
    | undefined
    | ((value: { salt: Uint8Array; iterations: number; iv: Uint8Array; wrap: Uint8Array }) => void),
  begin: vi.fn(),
}));
vi.mock('$lib/api', () => ({
  adminApi: {
    keyBundle: async () => ({
      ok: true,
      data: { rpId: 'example.test', accountPublicKey: null, wraps: [] },
    }),
    putAccountKey: async () => ({ ok: true }),
    beginRotation: fixture.begin,
  },
}));
vi.mock('$lib/api/webauthn', async (original) => ({
  ...(await original<typeof import('$lib/api/webauthn')>()),
  requestPrf: async () => ({ output: new Uint8Array(32), credentialId: new Uint8Array([1]) }),
}));
vi.mock('./keys', async (original) => ({
  ...(await original<typeof import('./keys')>()),
  generateKeyPair: async () => {
    const secret = new Uint8Array(32).fill(17);
    fixture.generated.push(secret);
    return { secret, publicKey: new Uint8Array(32).fill(1), kid: 'new-generation' };
  },
  wrapAccountKey: async () => ({ iv: new Uint8Array(12), wrap: new Uint8Array(48) }),
  grantAccess: async () => ({ enc: new Uint8Array(32), sealed: new Uint8Array(48) }),
  wrapRecovery: () =>
    new Promise((resolve) => {
      fixture.recovery = resolve;
    }),
}));
import { keyring } from './keyring.svelte';
const recovery = {
  salt: new Uint8Array(32),
  iterations: 600000,
  iv: new Uint8Array(12),
  wrap: new Uint8Array(48),
};
beforeEach(async () => {
  fixture.generated = [];
  fixture.recovery = undefined;
  fixture.begin.mockReset();
  await keyring.setupAccountKey();
  keyring.adopt('old-generation', new Uint8Array(32).fill(17));
});
afterEach(() => keyring.lock());

it('Sperren vor dem Rotationsrequest verhindert Versand und vernichtet den neuen Rohschlüssel', async () => {
  const run = keyring.beginRotation('tenant', 'self', 'old-generation', []);
  await vi.waitFor(() => expect(fixture.recovery).toBeDefined());
  keyring.lock();
  fixture.recovery!(recovery);
  expect(await run).toBe('locked');
  expect(fixture.begin).not.toHaveBeenCalled();
  expect(fixture.generated.at(-1)!.every((byte) => byte === 0)).toBe(true);
  expect(keyring.kids).toEqual([]);
});

it('fehlgeschlagener Rotationsrequest vernichtet den neuen Rohschlüssel', async () => {
  fixture.begin.mockResolvedValue({ ok: false, error: { status: 409 } });
  const run = keyring.beginRotation('tenant', 'self', 'old-generation', []);
  await vi.waitFor(() => expect(fixture.recovery).toBeDefined());
  fixture.recovery!(recovery);
  expect(await run).toBe('server');
  expect(fixture.generated.at(-1)!.every((byte) => byte === 0)).toBe(true);
  expect(keyring.kids).toEqual(['old-generation']);
});

it('Lock räumt laufende Rewrap-Kopien sofort auf und Wiederentsperren reaktiviert sie nicht', async () => {
  const operation = keyring.operation();
  const source = keyring.dataKey('old-generation')!;
  const copy = operation.copy(source);
  const encoded = operation.track(new Uint8Array(48).fill(17));
  keyring.lock();
  expect(copy.every((b) => b === 0)).toBe(true);
  expect(encoded.every((b) => b === 0)).toBe(true);
  keyring.adopt('old-generation', new Uint8Array(32).fill(17));
  expect(() => operation.check()).toThrow('gesperrt');
  const late = new Uint8Array(32).fill(17);
  expect(() => operation.track(late)).toThrow('gesperrt');
  expect(late.every((b) => b === 0)).toBe(true);
});

it('Lock während Hold-Krypto verhindert Versand, auch nach erneutem Adoptieren desselben kid', async () => {
  const { rewrapPackage } = await import('./rewrap');
  const { default: vectors } = await import('./fixtures/rotation.json');
  const secret = Uint8Array.from(vectors.oldSecret.match(/../g)!.map((h) => parseInt(h, 16)));
  keyring.adopt('hold', secret);
  const operation = keyring.operation();
  const copied: Uint8Array[] = [];
  const track = operation.track.bind(operation);
  vi.spyOn(operation, 'track').mockImplementation((buffer) => {
    copied.push(buffer);
    return track(buffer);
  });
  const send = vi.fn();
  const run = (async () => {
    const wire = await rewrapPackage(
      vectors.cases[0]!.source,
      secret,
      { wrap: 'sym', secret },
      undefined,
      operation,
    );
    operation.check();
    send(wire);
  })();
  // identity() is suspended at importKey; raw keys and PKCS8 copy already exist.
  expect(copied.length).toBeGreaterThanOrEqual(3);
  keyring.lock();
  expect(copied.every((buffer) => buffer.every((b) => b === 0))).toBe(true);
  keyring.adopt('hold', new Uint8Array(32).fill(17));
  await expect(run).rejects.toThrow('gesperrt');
  expect(send).not.toHaveBeenCalled();
  expect(copied.every((buffer) => buffer.every((b) => b === 0))).toBe(true);
});
