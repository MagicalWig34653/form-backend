// SPDX-License-Identifier: AGPL-3.0-only
// Browser key management (contracts/crypto/schluessel.md): account key wrapped by a passkey PRF output, customer data key
// granted to accounts via HPKE, recovery wrap under a passphrase. Nothing here talks to the server; callers persist the results.
import {
  PackageError,
  fromBase64Url,
  toBase64Url,
  bytes,
  cat,
  gcmOpen,
  gcmSeal,
  hkdf,
  hpkeOpen,
  hpkeSeal,
  identity,
  keyId,
  randomBytes,
} from './packageV2';

export interface Wrapped {
  iv: Uint8Array;
  wrap: Uint8Array;
}

export async function generateKeyPair(): Promise<{
  secret: Uint8Array;
  publicKey: Uint8Array;
  kid: string;
}> {
  const secret = randomBytes(32);
  const { publicKey, kid } = await identity(secret);
  return { secret, publicKey, kid };
}

// ---- account key under a passkey (PRF) ----

const ACCOUNT_LABEL = 'kubus-kontoschluessel v1';

async function kekPasskey(prfOutput: Uint8Array, credentialId: Uint8Array): Promise<Uint8Array> {
  if (prfOutput.length !== 32 || credentialId.length < 1 || credentialId.length > 255)
    throw new PackageError('format');
  return hkdf(prfOutput, credentialId, bytes(ACCOUNT_LABEL), 32);
}

export async function wrapAccountKey(
  accountSecret: Uint8Array,
  prfOutput: Uint8Array,
  credentialId: Uint8Array,
): Promise<Wrapped> {
  const iv = randomBytes(12);
  return {
    iv,
    wrap: await gcmSeal(
      await kekPasskey(prfOutput, credentialId),
      iv,
      accountSecret,
      bytes(ACCOUNT_LABEL),
    ),
  };
}

export async function unwrapAccountKey(
  w: Wrapped,
  prfOutput: Uint8Array,
  credentialId: Uint8Array,
): Promise<Uint8Array> {
  const secret = await gcmOpen(
    await kekPasskey(prfOutput, credentialId),
    w.iv,
    w.wrap,
    bytes(ACCOUNT_LABEL),
  );
  if (secret.length !== 32) throw new PackageError('format');
  return secret;
}

// ---- data access: sk_D sealed to the account's public key ----

const ACCESS_INFO = 'kubus-datenzugang v1';

export async function grantAccess(
  dataSecret: Uint8Array,
  accountPublic: Uint8Array,
  kid: string,
): Promise<{ enc: Uint8Array; sealed: Uint8Array }> {
  if ((await identity(dataSecret)).kid !== kid) throw new PackageError('keyMismatch');
  const r = await hpkeSeal(dataSecret, accountPublic, bytes(ACCESS_INFO), bytes(kid));
  return { enc: r.enc, sealed: r.ciphertext };
}

/** GCM success alone is not enough: the opened key must belong to the expected kid. */
export async function openAccess(
  enc: Uint8Array,
  sealed: Uint8Array,
  accountSecret: Uint8Array,
  kid: string,
): Promise<Uint8Array> {
  const secret = await hpkeOpen(enc, sealed, accountSecret, bytes(ACCESS_INFO), bytes(kid));
  if (secret.length !== 32 || (await identity(secret)).kid !== kid) {
    secret.fill(0);
    throw new PackageError('keyMismatch');
  }
  return secret;
}

// ---- recovery code ----

export const RECOVERY_ITERATIONS = 600000;
const RECOVERY_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/** Exactly the ECMAScript normalisation of the old UI: upper-case, then drop ASCII hyphen and whitespace. */
export function normalizeRecovery(value: string): string {
  return String(value || '')
    .toUpperCase()
    .replace(/[-\s]/g, '');
}

export function generateRecoveryCode(): string {
  const raw = randomBytes(32);
  const chars = [...raw].map((b) => RECOVERY_ALPHABET[b % 32]!);
  raw.fill(0);
  return Array.from({ length: 8 }, (_, i) => chars.slice(i * 4, i * 4 + 4).join('')).join('-');
}

async function kekRecovery(
  code: string,
  salt: Uint8Array,
  iterations: number,
): Promise<Uint8Array> {
  const normalized = normalizeRecovery(code);
  if (normalized.length < 24 || salt.length !== 32) throw new PackageError('format');
  const base = await globalThis.crypto.subtle.importKey(
    'raw',
    bytes(normalized).slice().buffer as ArrayBuffer,
    'PBKDF2',
    false,
    ['deriveBits'],
  );
  return new Uint8Array(
    await globalThis.crypto.subtle.deriveBits(
      { name: 'PBKDF2', hash: 'SHA-256', salt: salt.slice().buffer as ArrayBuffer, iterations },
      base,
      256,
    ),
  );
}

export async function wrapRecovery(
  dataSecret: Uint8Array,
  code: string,
  kid: string,
): Promise<{ salt: Uint8Array; iterations: number } & Wrapped> {
  const salt = randomBytes(32);
  const iv = randomBytes(12);
  const kek = await kekRecovery(code, salt, RECOVERY_ITERATIONS);
  try {
    return {
      salt,
      iterations: RECOVERY_ITERATIONS,
      iv,
      wrap: await gcmSeal(kek, iv, dataSecret, bytes(kid)),
    };
  } finally {
    kek.fill(0);
  }
}

export async function openRecovery(
  r: { salt: Uint8Array; iterations: number } & Wrapped,
  code: string,
  kid: string,
): Promise<Uint8Array> {
  if (r.iterations !== RECOVERY_ITERATIONS) throw new PackageError('format');
  const secret = await gcmOpen(
    await kekRecovery(code, r.salt, r.iterations),
    r.iv,
    r.wrap,
    bytes(kid),
  );
  if (secret.length !== 32 || (await identity(secret)).kid !== kid) {
    secret.fill(0);
    throw new PackageError('keyMismatch');
  }
  return secret;
}

/** Short human-comparable fingerprint of a public key (SHA-256, first 8 bytes, groups of four hex digits). */
export async function fingerprint(publicKey: Uint8Array): Promise<string> {
  return (await keyId(publicKey)).replace(/(.{4})(?=.)/g, '$1-');
}

export { cat, keyId };

// Separate AAD domain: an account envelope cannot be used as a customer recovery envelope.
export async function wrapAccountRecovery(secret: Uint8Array, code: string) {
  return wrapRecovery(secret, code, 'kubus-account-recovery-v1:' + (await identity(secret)).kid);
}
export async function openAccountRecovery(
  r: { salt: Uint8Array; iterations: number } & Wrapped,
  code: string,
  publicKey: string,
) {
  if (r.iterations !== RECOVERY_ITERATIONS) throw new PackageError('format');
  const kid = await keyId(fromBase64Url(publicKey));
  const kek = await kekRecovery(code, r.salt, r.iterations);
  let secret: Uint8Array;
  try {
    secret = await gcmOpen(kek, r.iv, r.wrap, bytes('kubus-account-recovery-v1:' + kid));
  } finally {
    kek.fill(0);
  }
  if (secret.length !== 32 || toBase64Url((await identity(secret)).publicKey) !== publicKey) {
    secret.fill(0);
    throw new PackageError('keyMismatch');
  }
  return secret;
}
