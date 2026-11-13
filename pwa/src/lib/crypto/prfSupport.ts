// SPDX-License-Identifier: AGPL-3.0-only
// Detection helpers for the WebAuthn PRF extension (hmac-secret). Nothing here is persisted and nothing is secret.

/** True when a client extension result carries a usable 32 byte PRF output. */
export function hasPrfOutput(results: unknown): boolean {
  const first = (results as { prf?: { results?: { first?: ArrayBuffer } } } | undefined)?.prf
    ?.results?.first;
  return first?.byteLength === 32;
}

/** Set by the last passkey ceremony: did it succeed without a PRF output? Read by the keyring (a hint, not a blocker). */
let missing = false;
export function notePrfOutcome(present: boolean): void {
  missing = !present;
}
export function prfWasMissing(): boolean {
  return missing;
}

export type PrfCapability = 'yes' | 'no' | 'unknown';

/** Asks getClientCapabilities() (where it exists) whether the extension is offered. Never throws; only a hint. */
export async function detectPrfCapability(
  pkc: unknown = typeof PublicKeyCredential === 'undefined' ? undefined : PublicKeyCredential,
): Promise<PrfCapability> {
  try {
    const f = (
      pkc as { getClientCapabilities?: () => Promise<Record<string, boolean>> } | undefined
    )?.getClientCapabilities;
    if (typeof f !== 'function') return 'unknown';
    const caps = await f.call(pkc);
    const v = caps?.['extension:prf'];
    return v === true ? 'yes' : v === false ? 'no' : 'unknown';
  } catch {
    return 'unknown';
  }
}
