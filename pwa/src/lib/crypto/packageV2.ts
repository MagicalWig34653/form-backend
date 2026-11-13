import type { KeyOperation } from './operation';
// SPDX-License-Identifier: AGPL-3.0-only
// Opens `KUBUS-AEAD:2` packages in the browser (contracts/crypto/paket-v2.md). The private data key stays in this
// tab's memory; the server only ever delivers the sealed package. Plain WebCrypto, HPKE (RFC 9180 base mode) by hand.

export class PackageError extends Error {}

const enc = new TextEncoder();
const bytes = (s: string): Uint8Array => enc.encode(s);
const cat = (...p: Uint8Array[]): Uint8Array => {
  const out = new Uint8Array(p.reduce((n, x) => n + x.length, 0));
  let o = 0;
  for (const x of p) {
    out.set(x, o);
    o += x.length;
  }
  return out;
};
const buf = (u: Uint8Array): ArrayBuffer => u.slice().buffer as ArrayBuffer;
const subtle = (): SubtleCrypto => {
  if (!globalThis.crypto?.subtle) throw new PackageError('WebCrypto nicht verfügbar');
  return globalThis.crypto.subtle;
};

function b64(s: string, length?: number): Uint8Array {
  let raw: string;
  try {
    raw = atob(s);
  } catch {
    throw new PackageError('format');
  }
  const out = Uint8Array.from(raw, (c) => c.charCodeAt(0));
  let back = '';
  for (const b of out) back += String.fromCharCode(b);
  if (btoa(back) !== s || (length !== undefined && out.length !== length))
    throw new PackageError('format');
  return out;
}

export function toBase64Url(u: Uint8Array): string {
  let s = '';
  for (const b of u) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64Url(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new PackageError('format');
  const std = s.replace(/-/g, '+').replace(/_/g, '/');
  return b64(std + '='.repeat((4 - (std.length % 4)) % 4));
}

export interface ParsedPackage {
  kid: string;
  wrap: 'hpke' | 'sym';
  a: Uint8Array;
  b: Uint8Array;
  iv: Uint8Array;
  ct: Uint8Array;
  tag: Uint8Array;
}

export function parsePackage(wire: string): ParsedPackage {
  const p = wire.split('|');
  if (p.length !== 7 || p[0] !== 'KUBUS-AEAD:2' || !/^[0-9a-f]{16}$/.test(p[1]!))
    throw new PackageError('format');
  const wrap = p[2];
  if (wrap !== 'hpke' && wrap !== 'sym') throw new PackageError('format');
  const w = p[3]!.split(':');
  if (w.length !== 2) throw new PackageError('format');
  return {
    kid: p[1]!,
    wrap,
    a: b64(w[0]!, wrap === 'hpke' ? 32 : 12),
    b: b64(w[1]!, 48),
    iv: b64(p[4]!, 12),
    ct: p[5] === '' ? new Uint8Array() : b64(p[5]!),
    tag: b64(p[6]!, 16),
  };
}

async function hmac(
  key: Uint8Array,
  data: Uint8Array,
  operation?: KeyOperation,
): Promise<Uint8Array> {
  const input = data.slice();
  const keyCopy = key.length ? key.slice() : new Uint8Array(32);
  try {
    operation?.track(input);
    operation?.track(keyCopy);
    const k = await subtle().importKey(
      'raw',
      keyCopy.buffer as ArrayBuffer,
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    operation?.check();
    return new Uint8Array(await subtle().sign('HMAC', k, input.buffer as ArrayBuffer));
  } finally {
    input.fill(0);
    keyCopy.fill(0);
  }
}
async function hkdfExpand(prk: Uint8Array, info: Uint8Array, length: number): Promise<Uint8Array> {
  let t: Uint8Array = new Uint8Array();
  const out: Uint8Array[] = [];
  for (let i = 1; out.reduce((n, x) => n + x.length, 0) < length; i++) {
    t = await hmac(prk, cat(t, info, Uint8Array.of(i)));
    out.push(t);
  }
  return new Uint8Array(cat(...out).slice(0, length));
}
const hkdf = async (
  ikm: Uint8Array,
  salt: Uint8Array,
  info: Uint8Array,
  length: number,
  operation?: KeyOperation,
): Promise<Uint8Array> => {
  const prk = await hmac(salt, ikm, operation);
  try {
    operation?.track(prk);
    return await hkdfExpand(prk, info, length);
  } finally {
    prk.fill(0);
  }
};

const KEM_SUITE = cat(bytes('KEM'), Uint8Array.of(0, 0x20));
const HPKE_SUITE = cat(bytes('HPKE'), Uint8Array.of(0, 0x20, 0, 1, 0, 2));
const lExtract = async (suite: Uint8Array, salt: Uint8Array, label: string, ikm: Uint8Array) =>
  hmac(salt, cat(bytes('HPKE-v1'), suite, bytes(label), ikm));
const lExpand = async (
  suite: Uint8Array,
  prk: Uint8Array,
  label: string,
  info: Uint8Array,
  length: number,
) =>
  hkdfExpand(
    prk,
    cat(Uint8Array.of(length >> 8, length & 255), bytes('HPKE-v1'), suite, bytes(label), info),
    length,
  );

const PKCS8_X25519 = Uint8Array.of(
  0x30,
  0x2e,
  0x02,
  0x01,
  0x00,
  0x30,
  0x05,
  0x06,
  0x03,
  0x2b,
  0x65,
  0x6e,
  0x04,
  0x22,
  0x04,
  0x20,
);

async function gcmOpen(
  key: Uint8Array,
  iv: Uint8Array,
  data: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  try {
    const k = await subtle().importKey('raw', buf(key), 'AES-GCM', false, ['decrypt']);
    return new Uint8Array(
      await subtle().decrypt(
        { name: 'AES-GCM', iv: buf(iv), additionalData: buf(aad), tagLength: 128 },
        k,
        buf(data),
      ),
    );
  } catch {
    throw new PackageError('auth');
  }
}

/** Public X25519 key and key id for a raw 32-byte private key. */
export async function identity(
  secret: Uint8Array,
  operation?: KeyOperation,
): Promise<{ publicKey: Uint8Array; kid: string }> {
  if (secret.length !== 32) throw new PackageError('format');
  // X25519 with the standard base point derives the public key without exporting a private JWK string.
  const base = new Uint8Array(32);
  base[0] = 9;
  const publicKey = await x25519(secret, base, operation);
  operation?.check();
  return { publicKey, kid: await keyId(publicKey) };
}

export async function keyId(publicKey: Uint8Array): Promise<string> {
  const h = new Uint8Array(await subtle().digest('SHA-256', buf(publicKey)));
  return [...h.slice(0, 8)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** Opens a package with the raw private data key. Throws PackageError (never returns partial data). */
export async function openPackage(wire: string, secret: Uint8Array): Promise<Uint8Array> {
  const pkg = parsePackage(wire);
  const cek = await unwrapContentKey(pkg, secret);
  try {
    return await gcmOpen(cek, pkg.iv, cat(pkg.ct, pkg.tag), bytes('KUBUS-AEAD:2'));
  } finally {
    cek.fill(0);
  }
}

/** The 32-byte content key of a package (for the server-side resend proof); the caller must wipe it. */
export async function contentKey(
  wire: string,
  secret: Uint8Array,
  operation?: KeyOperation,
): Promise<Uint8Array> {
  return unwrapContentKey(parsePackage(wire), secret, operation);
}

async function unwrapContentKey(
  pkg: ParsedPackage,
  secret: Uint8Array,
  operation?: KeyOperation,
): Promise<Uint8Array> {
  const { kid } = await identity(secret, operation);
  operation?.check();
  if (kid !== pkg.kid) throw new PackageError('keyMismatch');
  const kidBytes = bytes(pkg.kid);
  let cek: Uint8Array;
  if (pkg.wrap === 'hpke') {
    cek = await hpkeOpen(pkg.a, pkg.b, secret, bytes('kubus-anfrage v2'), kidBytes, operation);
  } else {
    const kek = await hkdf(secret, new Uint8Array(), bytes('kubus-langzeit v1'), 32, operation);
    try {
      operation?.track(kek);
      cek = await gcmOpen(kek, pkg.a, pkg.b, kidBytes);
    } finally {
      kek.fill(0);
    }
  }
  operation?.track(cek);
  if (cek.length !== 32) throw new PackageError('format');
  return cek;
}

// ---- HPKE (RFC 9180 base mode, DHKEM(X25519)/HKDF-SHA256/AES-256-GCM) as used by paket-v2.md and schluessel.md ----

async function x25519(
  secret: Uint8Array,
  peerPublic: Uint8Array,
  operation?: KeyOperation,
): Promise<Uint8Array> {
  let dh: Uint8Array;
  const encoded = cat(PKCS8_X25519, secret);
  operation?.track(encoded);
  try {
    const sk = await subtle().importKey(
      'pkcs8',
      encoded.buffer as ArrayBuffer,
      { name: 'X25519' },
      false,
      ['deriveBits'],
    );
    const peer = await subtle().importKey('raw', buf(peerPublic), { name: 'X25519' }, false, []);
    dh = new Uint8Array(await subtle().deriveBits({ name: 'X25519', public: peer }, sk, 256));
  } catch {
    throw new PackageError('auth');
  } finally {
    encoded.fill(0);
  }
  operation?.track(dh);
  if (dh.every((b) => b === 0)) throw new PackageError('auth');
  return dh;
}

async function hpkeSchedule(
  dh: Uint8Array,
  enc: Uint8Array,
  recipientPublic: Uint8Array,
  info: Uint8Array,
) {
  const empty = new Uint8Array();
  const eae = await lExtract(KEM_SUITE, empty, 'eae_prk', dh);
  const shared = await lExpand(KEM_SUITE, eae, 'shared_secret', cat(enc, recipientPublic), 32);
  const context = cat(
    Uint8Array.of(0),
    await lExtract(HPKE_SUITE, empty, 'psk_id_hash', empty),
    await lExtract(HPKE_SUITE, empty, 'info_hash', info),
  );
  const secretKey = await lExtract(HPKE_SUITE, shared, 'secret', empty);
  return {
    key: await lExpand(HPKE_SUITE, secretKey, 'key', context, 32),
    nonce: await lExpand(HPKE_SUITE, secretKey, 'base_nonce', context, 12),
  };
}

export async function hpkeOpen(
  enc: Uint8Array,
  ciphertext: Uint8Array,
  secret: Uint8Array,
  info: Uint8Array,
  aad: Uint8Array,
  operation?: KeyOperation,
): Promise<Uint8Array> {
  const { publicKey } = await identity(secret, operation);
  operation?.check();
  const dh = await x25519(secret, enc, operation);
  let key: Uint8Array | undefined;
  try {
    const schedule = await hpkeSchedule(dh, enc, publicKey, info);
    key = schedule.key;
    operation?.track(key);
    return await gcmOpen(key, schedule.nonce, ciphertext, aad);
  } finally {
    dh.fill(0);
    key?.fill(0);
  }
}

/** `ephemeral` only for fixed test vectors; production always draws a fresh random key. */
export async function hpkeSeal(
  plaintext: Uint8Array,
  recipientPublic: Uint8Array,
  info: Uint8Array,
  aad: Uint8Array,
  ephemeral: Uint8Array = randomBytes(32),
): Promise<{ enc: Uint8Array; ciphertext: Uint8Array }> {
  const enc = (await identity(ephemeral)).publicKey;
  const { key, nonce } = await hpkeSchedule(
    await x25519(ephemeral, recipientPublic),
    enc,
    recipientPublic,
    info,
  );
  return { enc, ciphertext: await gcmSeal(key, nonce, plaintext, aad) };
}

export function randomBytes(n: number): Uint8Array {
  return globalThis.crypto.getRandomValues(new Uint8Array(n));
}

export async function gcmSeal(
  key: Uint8Array,
  iv: Uint8Array,
  plaintext: Uint8Array,
  aad: Uint8Array,
): Promise<Uint8Array> {
  const k = await subtle().importKey('raw', buf(key), 'AES-GCM', false, ['encrypt']);
  return new Uint8Array(
    await subtle().encrypt(
      { name: 'AES-GCM', iv: buf(iv), additionalData: buf(aad), tagLength: 128 },
      k,
      buf(plaintext),
    ),
  );
}

export { gcmOpen, hkdf, bytes, cat };
