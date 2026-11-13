// @vitest-environment node
// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic key material only (ADR 0038). Nothing here comes from a real customer or the old system's secrets.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

const fixture = vi.hoisted(() => ({
  accountSecret: new Uint8Array(32),
  accountPublic: null as string | null,
  rotation: { active: null, retiring: null } as {
    active: { kid: string; publicKey: string } | null;
    retiring: { kid: string; publicKey: string } | null;
  },
  grant: vi.fn(),
}));
vi.mock('$lib/api', () => ({
  adminApi: {
    keyBundle: async () => ({
      ok: true,
      data: {
        rpId: 'example.test',
        accountPublicKey: fixture.accountPublic,
        wraps: [],
        access: [],
      },
    }),
    putAccountKey: async () => ({ ok: true }),
    rotation: async () => ({ ok: true, data: fixture.rotation }),
    grantKeyAccess: fixture.grant,
  },
}));
vi.mock('$lib/api/webauthn', async (original) => ({
  ...(await original<typeof import('$lib/api/webauthn')>()),
  requestPrf: async () => ({
    output: new Uint8Array(32).fill(5),
    credentialId: new Uint8Array([1]),
  }),
}));
vi.mock('./keys', async (original) => {
  const keys = await original<typeof import('./keys')>();
  return {
    ...keys,
    // the account key of this test is a known synthetic value, so the uploaded envelope can be opened again below
    generateKeyPair: async () => {
      const secret = fixture.accountSecret.slice();
      const { identity } = await import('./packageV2');
      const id = await identity(secret);
      return { secret, publicKey: id.publicKey, kid: id.kid };
    },
  };
});

import { identity, toBase64Url, bytes } from './packageV2';
import { openAccess, openRecovery, normalizeRecovery } from './keys';
import { parseLegacyPrivateKey, sealLegacyKey } from './legacyAdoption';
import { keyring } from './keyring.svelte';

const legacySecret = () => Uint8Array.from({ length: 32 }, (_, i) => (i * 29 + 3) & 0xff);
const otherSecret = () => Uint8Array.from({ length: 32 }, (_, i) => (i * 13 + 200) & 0xff);
const accountSecret = () => Uint8Array.from({ length: 32 }, (_, i) => (i * 7 + 90) & 0xff);
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
const b64 = (b: Uint8Array) => btoa(String.fromCharCode(...b));

async function generation(secret: Uint8Array) {
  const id = await identity(secret);
  return { kid: id.kid, publicKey: toBase64Url(id.publicKey) };
}

describe('parseLegacyPrivateKey', () => {
  it('liest Base64url, Standard-Base64 (mit/ohne Padding) und Hex zu denselben 32 Byte', () => {
    const raw = legacySecret();
    for (const text of [
      toBase64Url(raw),
      b64(raw),
      b64(raw).replace(/=$/, ''),
      hex(raw),
      ` ${toBase64Url(raw)}\n`,
    ])
      expect(parseLegacyPrivateKey(text)).toEqual(raw);
  });
  it('lehnt falsche Länge, gemischtes Alphabet und nicht kanonische Endbits ab', () => {
    const url = toBase64Url(legacySecret());
    for (const bad of [
      '',
      url.slice(1),
      url + 'A',
      hex(legacySecret()).slice(2),
      url.replace(/[A-Za-z0-9]/, '+').replace(/[A-Za-z0-9]$/, '_'),
      url.slice(0, 42) + 'B', // low bits set
      'KUBUS-AEAD:1|aaaa',
    ])
      expect(() => parseLegacyPrivateKey(bad)).toThrow();
  });
});

describe('sealLegacyKey', () => {
  it('passender Schlüssel: Hülle ist an den Kontoschlüssel gebunden und liefert denselben privaten Schlüssel', async () => {
    const secret = legacySecret();
    const account = accountSecret();
    const accountPublic = (await identity(account)).publicKey;
    const g = await generation(secret);
    const out = await sealLegacyKey(secret, [await generation(otherSecret()), g], accountPublic);
    expect(out.kid).toBe(g.kid);
    expect(out.enc.length).toBe(32);
    expect(out.sealed.length).toBe(48);
    const opened = await openAccess(out.enc, out.sealed, account, out.kid);
    expect(opened).toEqual(legacySecret());
    // another account key cannot open it
    await expect(openAccess(out.enc, out.sealed, otherSecret(), out.kid)).rejects.toThrow();
  });
  it('falscher Schlüssel oder abweichender öffentlicher Schlüssel wird abgelehnt', async () => {
    const accountPublic = (await identity(accountSecret())).publicKey;
    const g = await generation(legacySecret());
    await expect(sealLegacyKey(otherSecret(), [g], accountPublic)).rejects.toThrow('keyMismatch');
    const wrongPublic = { kid: g.kid, publicKey: toBase64Url(new Uint8Array(32).fill(9)) };
    await expect(sealLegacyKey(legacySecret(), [wrongPublic], accountPublic)).rejects.toThrow(
      'keyMismatch',
    );
    await expect(sealLegacyKey(legacySecret(), [], accountPublic)).rejects.toThrow('keyMismatch');
  });
});

describe('Alt-Recovery-Hülle (Format der alten schluessel-modell.js)', () => {
  // Independent re-implementation of the old writer (bvk www/src/krypto/schluessel-modell.js recoveryWickeln/kekR and
  // schluessel-seite.js normalisierePassphrase), NOT using keys.ts, so the format equality is really cross-checked.
  async function legacyWrap(skD: Uint8Array, passphrase: string, kid: string) {
    const normalized = String(passphrase || '')
      .toUpperCase()
      .replace(/[-\s]/g, '');
    const salt = Uint8Array.from({ length: 32 }, (_, i) => (i * 5 + 1) & 0xff);
    const iv = Uint8Array.from({ length: 12 }, (_, i) => (i * 11 + 7) & 0xff);
    const base = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(normalized),
      'PBKDF2',
      false,
      ['deriveBits'],
    );
    const kek = new Uint8Array(
      await crypto.subtle.deriveBits(
        { name: 'PBKDF2', hash: 'SHA-256', salt, iterations: 600000 },
        base,
        256,
      ),
    );
    const k = await crypto.subtle.importKey('raw', kek, 'AES-GCM', false, ['encrypt']);
    const wrap = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv, additionalData: new TextEncoder().encode(kid), tagLength: 128 },
        k,
        skD.slice().buffer as ArrayBuffer,
      ),
    );
    return { salt, iv, wrap, iterations: 600000 };
  }

  it('öffnet sich mit openRecovery (Bindestriche, Kleinschreibung, Leerzeichen egal) und prüft den kid', async () => {
    const skD = legacySecret();
    const { kid } = await identity(skD);
    const code = 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6789';
    const r = await legacyWrap(skD, code, kid);
    expect(r.wrap.length).toBe(48);
    expect(normalizeRecovery(' abcd efgh-jklm-npqr-stuv-wxyz-2345-6789 ')).toBe(
      normalizeRecovery(code),
    );
    const opened = await openRecovery(r, ' abcd efgh-jklm-npqr-stuv-wxyz-2345-6789 ', kid);
    expect(opened).toEqual(legacySecret());
    await expect(openRecovery(r, 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ-2345-6788', kid)).rejects.toThrow();
    await expect(openRecovery(r, code, '0123456789abcdef')).rejects.toThrow();
    expect(bytes(kid).length).toBe(16);
  }, 20_000);
});

describe('keyring.adoptLegacyKey', () => {
  beforeEach(async () => {
    fixture.accountSecret = accountSecret();
    fixture.accountPublic = null;
    fixture.grant.mockReset();
    fixture.grant.mockResolvedValue({ ok: true, data: undefined });
    await keyring.setupAccountKey();
    fixture.accountPublic = toBase64Url((await identity(accountSecret())).publicKey);
    fixture.rotation = {
      active: await generation(otherSecret()),
      retiring: await generation(legacySecret()),
    };
  });
  afterEach(() => keyring.lock());

  it('passender Schlüssel: lädt nur die Hülle für das eigene Konto hoch und nullt die Eingabe', async () => {
    const input = legacySecret();
    const result = await keyring.adoptLegacyKey('tenant', 'me', input);
    const { kid } = await identity(legacySecret());
    expect(result).toEqual({ kid });
    expect(input.every((b) => b === 0)).toBe(true);
    expect(fixture.grant).toHaveBeenCalledTimes(1);
    const [tenant, target, body] = fixture.grant.mock.calls[0]!;
    expect([tenant, target, body.kid]).toEqual(['tenant', 'me', kid]);
    expect(Object.keys(body).sort()).toEqual(['enc', 'kid', 'sealed']);
    const { fromBase64Url } = await import('$lib/api/webauthn');
    const opened = await openAccess(
      fromBase64Url(body.enc),
      fromBase64Url(body.sealed),
      accountSecret(),
      kid,
    );
    expect(opened).toEqual(legacySecret());
    expect(JSON.stringify(body)).not.toContain(toBase64Url(legacySecret()));
    expect(keyring.dataKey(kid)).toEqual(legacySecret());
  });

  it('falscher Schlüssel: kein Upload, Eingabe genullt, Ergebnis mismatch', async () => {
    const input = Uint8Array.from({ length: 32 }, (_, i) => (i * 3 + 1) & 0xff);
    expect(await keyring.adoptLegacyKey('tenant', 'me', input)).toBe('mismatch');
    expect(input.every((b) => b === 0)).toBe(true);
    expect(fixture.grant).not.toHaveBeenCalled();
  });

  it('Serverfehler beim Upload: Schlüssel wird nicht behalten und die Eingabe genullt', async () => {
    fixture.grant.mockResolvedValue({ ok: false, error: { kind: 'http', status: 409 } });
    const input = legacySecret();
    expect(await keyring.adoptLegacyKey('tenant', 'me', input)).toBe('server');
    expect(input.every((b) => b === 0)).toBe(true);
    expect(keyring.dataKey((await identity(legacySecret())).kid)).toBeUndefined();
  });

  it('weicht der Kontoschlüssel des Servers ab, wird nichts versiegelt', async () => {
    fixture.accountPublic = toBase64Url((await identity(otherSecret())).publicKey);
    const input = legacySecret();
    expect(await keyring.adoptLegacyKey('tenant', 'me', input)).toBe('server');
    expect(fixture.grant).not.toHaveBeenCalled();
    expect(input.every((b) => b === 0)).toBe(true);
  });

  it('gesperrter Schlüsselbund: nichts geschieht, Eingabe genullt', async () => {
    keyring.lock();
    const input = legacySecret();
    expect(await keyring.adoptLegacyKey('tenant', 'me', input)).toBe('locked');
    expect(input.every((b) => b === 0)).toBe(true);
    expect(fixture.grant).not.toHaveBeenCalled();
  });
});
