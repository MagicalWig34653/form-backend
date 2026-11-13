// SPDX-License-Identifier: AGPL-3.0-only
// Adoption of an imported legacy customer key (ADR 0038). The old private X25519 data key is typed into THIS browser,
// checked against the public key of an imported generation and sealed to the own account key with the normal access
// envelope (keys.ts grantAccess). Only the envelope leaves the browser; the private key never does. No RSA/CBC/:1 (ADR 0001).
import { PackageError, identity, toBase64Url } from './packageV2';
import { grantAccess } from './keys';

export interface LegacyGeneration {
  kid: string;
  publicKey: string;
}

/**
 * Parses the pasted private key: 32 raw bytes as base64url, standard base64 (padding optional) or 64 hex digits.
 * Surrounding whitespace is ignored. The result is a fresh buffer the caller owns and must wipe.
 */
export function parseLegacyPrivateKey(input: string): Uint8Array {
  const value = input.trim();
  const out = new Uint8Array(32);
  if (/^[0-9a-fA-F]{64}$/.test(value)) {
    for (let i = 0; i < 32; i++) out[i] = parseInt(value.slice(i * 2, i * 2 + 2), 16);
    return out;
  }
  // 32 bytes = 43 significant characters; one alphabet only, and the 2 unused low bits must be zero (canonical form).
  if (!/^[A-Za-z0-9+/_-]{43}=?$/.test(value) || (/[+/]/.test(value) && /[_-]/.test(value)))
    throw new PackageError('format');
  // Decoded straight into the byte buffer (no intermediate binary string holding the key).
  let acc = 0;
  let bits = 0;
  let n = 0;
  for (let i = 0; i < 43; i++) {
    const c = value.charCodeAt(i);
    const v =
      c >= 65 && c <= 90
        ? c - 65
        : c >= 97 && c <= 122
          ? c - 71
          : c >= 48 && c <= 57
            ? c + 4
            : c === 43 || c === 45
              ? 62
              : 63;
    acc = ((acc << 6) | v) & 0xffff;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[n++] = (acc >> bits) & 0xff;
    }
  }
  const rest = acc & ((1 << bits) - 1);
  if (n !== 32 || rest !== 0) {
    out.fill(0);
    throw new PackageError('format');
  }
  return out;
}

/**
 * Derives the public key of `secret` locally and requires an EXACT match (kid and 32-byte public key) with one of the
 * generations the server lists for the customer. Then seals the key to `accountPublic` (HPKE, info "kubus-datenzugang v1",
 * AAD = kid). Throws PackageError('keyMismatch') when the key belongs to none of them; never reveals which part differed.
 */
export async function sealLegacyKey(
  secret: Uint8Array,
  generations: LegacyGeneration[],
  accountPublic: Uint8Array,
): Promise<{ kid: string; enc: Uint8Array; sealed: Uint8Array }> {
  if (secret.length !== 32 || accountPublic.length !== 32) throw new PackageError('format');
  const own = await identity(secret);
  const publicKey = toBase64Url(own.publicKey);
  const generation = generations.find((g) => g.kid === own.kid && g.publicKey === publicKey);
  if (!generation) throw new PackageError('keyMismatch');
  const access = await grantAccess(secret, accountPublic, generation.kid);
  return { kid: generation.kid, enc: access.enc, sealed: access.sealed };
}
