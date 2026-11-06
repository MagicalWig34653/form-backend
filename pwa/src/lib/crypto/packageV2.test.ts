// @vitest-environment node
import { describe, expect, it } from 'vitest';
import fixture from './synthetic.fixture.json';
import {
  PackageError,
  contentKey,
  fromBase64Url,
  identity,
  openPackage,
  parsePackage,
  toBase64Url,
} from './packageV2';

const hex = (s: string): Uint8Array => Uint8Array.from(s.match(/../g)!.map((h) => parseInt(h, 16)));
const toHex = (u: Uint8Array): string =>
  [...u].map((b) => b.toString(16).padStart(2, '0')).join('');
const sk = hex(fixture.sk);

describe('KUBUS-AEAD:2 im Browser', () => {
  it('leitet Public Key und kid aus dem privaten Schlüssel ab', async () => {
    const id = await identity(sk);
    expect(toHex(id.publicKey)).toBe(fixture.pk);
    expect(id.kid).toBe('d19bf3f082782c87');
  });

  it('öffnet alle PHP-erzeugten Pakete der Fixture (hpke)', async () => {
    for (const p of fixture.packets) {
      const plain = await openPackage(p.packet, sk);
      expect(toHex(plain), p.id).toBe(p.plaintext);
    }
    expect(fixture.packets.length).toBeGreaterThan(1);
  });

  it('öffnet das sym-Paket', async () => {
    expect((await openPackage(fixture.symPacket, sk)).length).toBe(0);
  });

  it('lehnt falschen Schlüssel, manipuliertes Chiffrat und kaputtes Format ab', async () => {
    const wire = fixture.packets.find((p) => p.plaintext.length > 0)!.packet;
    await expect(openPackage(wire, new Uint8Array(32).fill(7))).rejects.toThrow(PackageError);
    const parts = wire.split('|');
    const ct = atob(parts[5]!);
    parts[5] = btoa(String.fromCharCode(ct.charCodeAt(0) ^ 1) + ct.slice(1));
    await expect(openPackage(parts.join('|'), sk)).rejects.toThrow(PackageError);
    expect(() => parsePackage(wire + '\n')).toThrow(PackageError);
    expect(() => parsePackage('KUBUS-AEAD:1|x')).toThrow(PackageError);
  });

  it('liest base64url strikt', () => {
    expect(fromBase64Url('3q2-7w').length).toBe(4);
    expect(() => fromBase64Url('a+b')).toThrow(PackageError);
  });

  it('liefert den Inhaltsschlüssel (32 Byte, base64url-Rundlauf) und lehnt falschen Schlüssel ab', async () => {
    const wire = fixture.packets[1]!.packet;
    const cek = await contentKey(wire, sk);
    expect(cek.length).toBe(32);
    expect(fromBase64Url(toBase64Url(cek))).toEqual(cek);
    await expect(contentKey(wire, new Uint8Array(32).fill(7))).rejects.toThrow(PackageError);
  });
});
