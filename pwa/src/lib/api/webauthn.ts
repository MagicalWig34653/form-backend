import { hasPrfOutput, notePrfOutcome } from '$lib/crypto/prfSupport';

/** Strict base64url (no padding) helpers and the WebAuthn assertion request, wire format per
 * contracts/auth/p5b-ergaenzung.md E2. */

export function toBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let bin = '';
  for (const b of view) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromBase64Url(text: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/.test(text)) throw new Error('invalid base64url');
  const padded =
    text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (text.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export interface PasskeyOptions {
  challengeId: string;
  publicKey: {
    challenge: string;
    rpId: string;
    timeout: number;
    userVerification: 'required' | 'preferred' | 'discouraged';
    allowCredentials: unknown[];
  };
  expiresAt: string;
}

export interface PasskeyCredentialBody {
  challengeId: string;
  credential: {
    id: string;
    rawId: string;
    type: 'public-key';
    response: {
      authenticatorData: string;
      clientDataJSON: string;
      signature: string;
      userHandle?: string;
    };
  };
}

// Public, versioned input; credential-specific HKDF still separates account wraps.
export const LOGIN_PRF_SALT = new TextEncoder().encode('kubus-login-prf-v1-0000000000000');

export type PasskeyOutcome =
  | { ok: true; body: PasskeyCredentialBody; prf?: PrfResult }
  | { ok: false; reason: 'unsupported' | 'cancelled' | 'failed' };

/** `{type:'public-key', id}` entries of the options (the login sends none; the step-up names the account's own passkeys). */
function allowList(options: PasskeyOptions): PublicKeyCredentialDescriptor[] {
  const out: PublicKeyCredentialDescriptor[] = [];
  const list: unknown = options.publicKey.allowCredentials;
  if (!Array.isArray(list)) return out;
  for (const c of list) {
    const id = (c as { id?: unknown } | null)?.id;
    if (typeof id !== 'string') continue;
    try {
      out.push({ type: 'public-key', id: fromBase64Url(id) });
    } catch {
      /* a malformed id is skipped; the server decides anyway */
    }
  }
  return out;
}

/**
 * Asks the authenticator for an assertion. Never throws; maps the browser's errors to a small set of reasons.
 * `prf: false` leaves out the PRF extension (step-up: only the signature matters, no key material is derived).
 */
export async function requestAssertion(
  options: PasskeyOptions,
  credentials: Pick<CredentialsContainer, 'get'> | undefined = typeof navigator === 'undefined'
    ? undefined
    : navigator.credentials,
  settings: { prf?: boolean } = {},
): Promise<PasskeyOutcome> {
  if (!credentials || typeof PublicKeyCredential === 'undefined')
    return { ok: false, reason: 'unsupported' };
  let cred: Credential | null;
  try {
    cred = await credentials.get({
      publicKey: {
        challenge: fromBase64Url(options.publicKey.challenge),
        rpId: options.publicKey.rpId,
        timeout: options.publicKey.timeout,
        userVerification: options.publicKey.userVerification,
        allowCredentials: allowList(options),
        ...(settings.prf === false
          ? {}
          : {
              extensions: {
                prf: { eval: { first: LOGIN_PRF_SALT } },
              } as AuthenticationExtensionsClientInputs,
            }),
      },
    });
  } catch (e) {
    const name = (e as { name?: string })?.name;
    return {
      ok: false,
      reason: name === 'NotAllowedError' || name === 'AbortError' ? 'cancelled' : 'failed',
    };
  }
  const pk = cred as PublicKeyCredential | null;
  const r = pk?.response as AuthenticatorAssertionResponse | undefined;
  if (!pk || !r || !r.authenticatorData) return { ok: false, reason: 'failed' };
  const first = (
    pk.getClientExtensionResults?.() as { prf?: { results?: { first?: ArrayBuffer } } } | undefined
  )?.prf?.results?.first;
  return {
    ok: true,
    ...(first?.byteLength === 32
      ? { prf: { credentialId: new Uint8Array(pk.rawId), output: new Uint8Array(first) } }
      : {}),
    body: {
      challengeId: options.challengeId,
      credential: {
        id: pk.id,
        rawId: toBase64Url(pk.rawId),
        type: 'public-key',
        response: {
          authenticatorData: toBase64Url(r.authenticatorData),
          clientDataJSON: toBase64Url(r.clientDataJSON),
          signature: toBase64Url(r.signature),
          ...(r.userHandle && r.userHandle.byteLength > 0
            ? { userHandle: toBase64Url(r.userHandle) }
            : {}),
        },
      },
    },
  };
}

export interface CreationOptions {
  challengeId: string;
  publicKey: {
    challenge: string;
    rp: { id: string; name: string };
    user: { id: string; name: string; displayName: string };
    pubKeyCredParams: { type: 'public-key'; alg: number }[];
    timeout: number;
    attestation: 'none';
    authenticatorSelection: {
      residentKey: 'required';
      requireResidentKey: true;
      userVerification: 'required';
    };
    excludeCredentials: { type: 'public-key'; id: string }[];
  };
  expiresAt: string;
}

export interface RegistrationBody {
  challengeId: string;
  label: string;
  token?: string;
  credential: {
    id: string;
    rawId: string;
    type: 'public-key';
    response: { attestationObject: string; clientDataJSON: string };
  };
}

export type RegistrationOutcome =
  | { ok: true; body: Omit<RegistrationBody, 'label' | 'token'> }
  | { ok: false; reason: 'unsupported' | 'cancelled' | 'duplicate' | 'failed' };

/** Asks the authenticator to create a passkey. Never throws; maps the browser's errors to a small set of reasons. */
export async function createCredential(
  options: CreationOptions,
  credentials: Pick<CredentialsContainer, 'create'> | undefined = typeof navigator === 'undefined'
    ? undefined
    : navigator.credentials,
): Promise<RegistrationOutcome> {
  if (!credentials || typeof PublicKeyCredential === 'undefined')
    return { ok: false, reason: 'unsupported' };
  const pk = options.publicKey;
  let cred: Credential | null;
  try {
    cred = await credentials.create({
      publicKey: {
        challenge: fromBase64Url(pk.challenge),
        rp: pk.rp,
        user: {
          id: fromBase64Url(pk.user.id),
          name: pk.user.name,
          displayName: pk.user.displayName,
        },
        pubKeyCredParams: pk.pubKeyCredParams,
        timeout: pk.timeout,
        attestation: pk.attestation,
        authenticatorSelection: pk.authenticatorSelection,
        excludeCredentials: pk.excludeCredentials.map((c) => ({
          type: c.type,
          id: fromBase64Url(c.id),
        })),
        // Without this at creation time an authenticator will not derive PRF secrets later (key unlock, schluessel.md).
        extensions: { prf: {} } as AuthenticationExtensionsClientInputs,
      },
    });
  } catch (e) {
    const name = (e as { name?: string })?.name;
    if (name === 'InvalidStateError') return { ok: false, reason: 'duplicate' };
    return {
      ok: false,
      reason: name === 'NotAllowedError' || name === 'AbortError' ? 'cancelled' : 'failed',
    };
  }
  const c = cred as PublicKeyCredential | null;
  const r = c?.response as AuthenticatorAttestationResponse | undefined;
  if (!c || !r || !r.attestationObject) return { ok: false, reason: 'failed' };
  return {
    ok: true,
    body: {
      challengeId: options.challengeId,
      credential: {
        id: c.id,
        rawId: toBase64Url(c.rawId),
        type: 'public-key',
        response: {
          attestationObject: toBase64Url(r.attestationObject),
          clientDataJSON: toBase64Url(r.clientDataJSON),
        },
      },
    },
  };
}

export interface PrfResult {
  credentialId: Uint8Array;
  output: Uint8Array;
}

/**
 * Local passkey ceremony that yields the PRF output (account key unlock; contracts/crypto/schluessel.md). It is NOT a login:
 * the server never sees the result. Either `evalByCredential` (known credentials with their salts) or one `salt` for whichever
 * credential the user picks (first setup). Returns null when PRF is unsupported or the user cancels.
 */
export async function requestPrf(
  rpId: string,
  input: { byCredential: { credentialId: Uint8Array; salt: Uint8Array }[] } | { salt: Uint8Array },
  credentials: Pick<CredentialsContainer, 'get'> | undefined = typeof navigator === 'undefined'
    ? undefined
    : navigator.credentials,
): Promise<PrfResult | null> {
  if (!credentials || typeof PublicKeyCredential === 'undefined') return null;
  notePrfOutcome(true);
  const prf: Record<string, unknown> =
    'byCredential' in input
      ? {
          evalByCredential: Object.fromEntries(
            input.byCredential.map((c) => [toBase64Url(c.credentialId), { first: c.salt }]),
          ),
        }
      : { eval: { first: input.salt } };
  try {
    const cred = (await credentials.get({
      publicKey: {
        challenge: crypto.getRandomValues(new Uint8Array(32)),
        rpId,
        userVerification: 'required',
        timeout: 60000,
        allowCredentials:
          'byCredential' in input
            ? input.byCredential.map((c) => ({
                type: 'public-key' as const,
                id: c.credentialId as BufferSource,
              }))
            : [],
        extensions: { prf } as AuthenticationExtensionsClientInputs,
      },
    })) as PublicKeyCredential | null;
    if (!cred) return null;
    const ext = cred.getClientExtensionResults() as { prf?: { results?: { first?: ArrayBuffer } } };
    const first = ext.prf?.results?.first;
    // A ceremony that succeeded without a PRF value is "browser/passkey gives no key", unlike a cancel (throws above).
    notePrfOutcome(hasPrfOutput(ext));
    if (!first || first.byteLength !== 32) return null;
    return { credentialId: new Uint8Array(cred.rawId), output: new Uint8Array(first) };
  } catch {
    return null;
  }
}
