// @vitest-environment node
import { describe, expect, it } from 'vitest';
import fixture from './synthetic.fixture.json';
import { PackageError, bytes, hpkeSeal, identity, parsePackage } from './packageV2';
import {
  generateKeyPair,
  generateRecoveryCode,
  grantAccess,
  normalizeRecovery,
  openAccess,
  openRecovery,
  unwrapAccountKey,
  wrapAccountKey,
  wrapRecovery,
} from './keys';

const hex = (s: string): Uint8Array => Uint8Array.from(s.match(/../g)!.map((h) => parseInt(h, 16)));
const b64 = (u: Uint8Array): string => btoa(String.fromCharCode(...u));

describe('Schlüsselverwaltung im Browser', () => {
  it('HPKE-Seal erzeugt byteidentisch das PHP-Paket (feste Test-Ephemeral)', async () => {
    const pkt = fixture.packets[1]!.packet; // sealed in the PHP harness with skE=22.., cek=33..
    const p = parsePackage(pkt);
    const r = await hpkeSeal(
      hex(fixture.cek),
      hex(fixture.pk),
      bytes('kubus-anfrage v2'),
      bytes(p.kid),
      hex(fixture.skE),
    );
    expect(b64(r.enc)).toBe(b64(p.a));
    expect(b64(r.ciphertext)).toBe(b64(p.b));
  });

  it('Kontoschlüssel: Wrap/Unwrap mit PRF-Ausgabe, falsche PRF/Credential-ID scheitern', async () => {
    const account = await generateKeyPair();
    const prf = new Uint8Array(32).fill(9);
    const cred = Uint8Array.of(1, 2, 3, 4);
    const w = await wrapAccountKey(account.secret, prf, cred);
    expect(w.iv.length).toBe(12);
    expect(w.wrap.length).toBe(48);
    expect(await unwrapAccountKey(w, prf, cred)).toEqual(account.secret);
    await expect(unwrapAccountKey(w, new Uint8Array(32).fill(8), cred)).rejects.toThrow(
      PackageError,
    );
    await expect(unwrapAccountKey(w, prf, Uint8Array.of(1, 2, 3, 5))).rejects.toThrow(PackageError);
  });

  it('Datenzugang: Konto öffnet nur den Schlüssel zum erwarteten kid', async () => {
    const account = await generateKeyPair();
    const data = await generateKeyPair();
    const g = await grantAccess(data.secret, account.publicKey, data.kid);
    expect(g.enc.length).toBe(32);
    expect(g.sealed.length).toBe(48);
    expect(await openAccess(g.enc, g.sealed, account.secret, data.kid)).toEqual(data.secret);
    await expect(openAccess(g.enc, g.sealed, account.secret, '0000000000000000')).rejects.toThrow(
      PackageError,
    );
    const other = await generateKeyPair();
    await expect(openAccess(g.enc, g.sealed, other.secret, data.kid)).rejects.toThrow(PackageError);
    await expect(grantAccess(data.secret, account.publicKey, '0000000000000000')).rejects.toThrow(
      PackageError,
    );
  });

  it('Recovery: Format, Normalisierung, Öffnen, falscher Code', async () => {
    const code = generateRecoveryCode();
    expect(code).toMatch(/^([A-HJ-NP-Z2-9]{4}-){7}[A-HJ-NP-Z2-9]{4}$/);
    expect(normalizeRecovery(' ab-cd\tef ')).toBe('ABCDEF');
    const data = await generateKeyPair();
    const r = await wrapRecovery(data.secret, code, data.kid);
    expect(r.iterations).toBe(600000);
    expect(await openRecovery(r, code.toLowerCase().replace(/-/g, ' '), data.kid)).toEqual(
      data.secret,
    );
    await expect(openRecovery(r, generateRecoveryCode(), data.kid)).rejects.toThrow(PackageError);
    await expect(openRecovery({ ...r, iterations: 1000 }, code, data.kid)).rejects.toThrow(
      PackageError,
    );
  }, 30000);

  it('Schlüsselpaare haben passende Public Keys', async () => {
    const k = await generateKeyPair();
    expect((await identity(k.secret)).kid).toBe(k.kid);
  });
});
