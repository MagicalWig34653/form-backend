// SPDX-License-Identifier: AGPL-3.0-only
import {
  PackageError,
  bytes,
  contentKey,
  gcmSeal,
  hkdf,
  hpkeSeal,
  identity,
  keyId,
  parsePackage,
  randomBytes,
} from './packageV2';

import { KeyOperation } from './operation';

export type RewrapTarget =
  { wrap: 'hpke'; publicKey: Uint8Array; secret: Uint8Array } | { wrap: 'sym'; secret: Uint8Array };

const b64 = (value: Uint8Array): string => btoa(String.fromCharCode(...value));

/** Replaces only the CEK envelope. Payload bytes, IV and authentication tag stay unchanged.
 * Deterministic randomness is exclusively for public cross-language fixtures.
 */
export async function rewrapPackage(
  wire: string,
  oldSecret: Uint8Array,
  target: RewrapTarget,
  testRandomness?: { ephemeral?: Uint8Array; iv?: Uint8Array },
  scope?: KeyOperation,
): Promise<string> {
  const operation = scope ?? new KeyOperation();
  const old = operation.copy(oldSecret);
  const next = operation.copy(target.secret);
  let cek: Uint8Array | undefined;
  let verified: Uint8Array | undefined;
  let kek: Uint8Array | undefined;
  try {
    const source = parsePackage(wire);
    if (source.wrap === 'sym' && target.wrap === 'hpke') throw new PackageError('wrapDowngrade');
    cek = await contentKey(wire, old, operation);
    operation.check();
    let kid: string, a: Uint8Array, b: Uint8Array;
    if (target.wrap === 'hpke') {
      if (target.publicKey.length !== 32) throw new PackageError('format');
      kid = await keyId(target.publicKey);
      const sealed = await hpkeSeal(
        cek,
        target.publicKey,
        bytes('kubus-anfrage v2'),
        bytes(kid),
        testRandomness?.ephemeral,
      );
      a = sealed.enc;
      b = sealed.ciphertext;
    } else {
      kid = (await identity(next, operation)).kid;
      kek = await hkdf(next, new Uint8Array(), bytes('kubus-langzeit v1'), 32, operation);
      operation.track(kek);
      a = testRandomness?.iv ?? randomBytes(12);
      if (a.length !== 12) throw new PackageError('format');
      b = await gcmSeal(kek, a, cek, bytes(kid));
    }
    // Reuse the strictly parsed original payload segments without processing plaintext.
    const result = [
      'KUBUS-AEAD:2',
      kid,
      target.wrap,
      `${b64(a)}:${b64(b)}`,
      ...wire.split('|').slice(4),
    ].join('|');
    operation.check();
    verified = await contentKey(result, next, operation);
    if (verified.length !== cek.length || verified.some((byte, i) => byte !== cek![i]))
      throw new PackageError('keyMismatch');
    operation.check();
    return result;
  } finally {
    old.fill(0);
    next.fill(0);
    cek?.fill(0);
    verified?.fill(0);
    kek?.fill(0);
    if (!scope) operation.dispose();
  }
}
