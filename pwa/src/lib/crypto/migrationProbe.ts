// SPDX-License-Identifier: AGPL-3.0-only
import { bytes, gcmSeal, hpkeSeal, identity, openPackage, randomBytes } from './packageV2';

export async function ciphertextHash(wire: string): Promise<string> {
  return [
    ...new Uint8Array(await crypto.subtle.digest('SHA-256', bytes(wire).buffer as ArrayBuffer)),
  ]
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}
const base64 = (value: Uint8Array) => btoa(String.fromCharCode(...value));

/** Only :2/X25519 migrated samples are supported. No RSA/CBC fallback. */
export async function verifyMigrationProbe(
  wire: string,
  expectedHash: string,
  secret: Uint8Array,
  confirm: (hash: string) => Promise<void>,
): Promise<string> {
  let plain: Uint8Array | undefined;
  const cek = randomBytes(32);
  try {
    if ((await ciphertextHash(wire)) !== expectedHash) throw new Error('probeMismatch');
    plain = await openPackage(wire, secret);
    plain.fill(0);
    // Require explicit human confirmation before generating the fresh test message.
    await confirm(expectedHash);
    const recipient = await identity(secret);
    const iv = randomBytes(12);
    const message = bytes('Migration: lokale Testnachricht');
    const encrypted = await gcmSeal(cek, iv, message, bytes('KUBUS-AEAD:2'));
    const wrapped = await hpkeSeal(
      cek,
      recipient.publicKey,
      bytes('kubus-anfrage v2'),
      bytes(recipient.kid),
    );
    const testWire = `KUBUS-AEAD:2|${recipient.kid}|hpke|${base64(wrapped.enc)}:${base64(wrapped.ciphertext)}|${base64(iv)}|${base64(encrypted.slice(0, -16))}|${base64(encrypted.slice(-16))}`;
    const opened = await openPackage(testWire, secret);
    try {
      if (!opened.every((b, i) => b === message[i]) || opened.length !== message.length)
        throw new Error('testMismatch');
      return await ciphertextHash(testWire);
    } finally {
      opened.fill(0);
      message.fill(0);
    }
  } finally {
    plain?.fill(0);
    cek.fill(0);
    secret.fill(0);
  }
}
