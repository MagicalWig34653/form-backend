import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const recovery = vi.hoisted(() => ({
  release: undefined as undefined | ((v: Uint8Array) => void),
}));
vi.mock('$lib/api', () => ({
  adminApi: {
    keyRecovery: async () => ({
      ok: true,
      data: {
        keyId: '0123456789abcdef',
        salt: 'AAAA',
        iv: 'AAAA',
        wrap: 'AAAA',
        iterations: 600000,
      },
    }),
  },
}));
vi.mock('./keys', async (orig) => ({
  ...(await orig<typeof import('./keys')>()),
  openRecovery: () => new Promise<Uint8Array>((r) => (recovery.release = r)),
}));
vi.mock('$lib/api/webauthn', async (orig) => ({
  ...(await orig<typeof import('$lib/api/webauthn')>()),
  fromBase64Url: () => new Uint8Array(),
}));

import { keyring } from './keyring.svelte';

describe('Keyring-Sperre', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => {
    keyring.lock();
    vi.useRealTimers();
  });

  it('eine vor dem Sperren gestartete Wiederherstellung füllt den Bund danach nicht wieder (H2)', async () => {
    const run = keyring.recover('t', 'code', '0123456789abcdef');
    await vi.advanceTimersByTimeAsync(0);
    keyring.lock();
    const secret = new Uint8Array(32).fill(7);
    recovery.release!(secret);
    expect(await run).toBe('locked');
    expect(keyring.kids).toEqual([]);
    expect(keyring.dataKey('0123456789abcdef')).toBeUndefined();
    expect([...secret].every((b) => b === 0)).toBe(true); // the late result was wiped
  });

  it('sperrt nach 10 Minuten ohne Nutzung, Nutzung verlängert (M5)', async () => {
    keyring.adopt('0123456789abcdef', new Uint8Array(32).fill(3));
    await vi.advanceTimersByTimeAsync(9 * 60_000);
    expect(keyring.dataKey('0123456789abcdef')).toBeDefined(); // use resets the clock
    await vi.advanceTimersByTimeAsync(9 * 60_000);
    expect(keyring.kids).toEqual(['0123456789abcdef']);
    await vi.advanceTimersByTimeAsync(2 * 60_000);
    expect(keyring.kids).toEqual([]);
    expect(keyring.dataKey('0123456789abcdef')).toBeUndefined();
  });

  it('wiederholtes Merken desselben kid überschreibt den alten Puffer', () => {
    const a = new Uint8Array(32).fill(1);
    const b = new Uint8Array(32).fill(2);
    keyring.adopt('0123456789abcdef', a);
    keyring.adopt('0123456789abcdef', b);
    expect([...a].every((x) => x === 0)).toBe(true);
    expect(keyring.dataKey('0123456789abcdef')).toBe(b);
  });
});
