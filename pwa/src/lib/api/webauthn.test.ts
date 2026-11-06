import { describe, expect, it } from 'vitest';
import {
  createCredential,
  fromBase64Url,
  requestAssertion,
  toBase64Url,
  type CreationOptions,
  type PasskeyOptions,
} from './webauthn';

const options: PasskeyOptions = {
  challengeId: 'c1',
  publicKey: {
    challenge: toBase64Url(new Uint8Array([1, 2, 3, 250, 251, 252])),
    rpId: 'admin.example.test',
    timeout: 120000,
    userVerification: 'required',
    allowCredentials: [],
  },
  expiresAt: 'e',
};

describe('base64url', () => {
  it('round-trips without padding and rejects other alphabets', () => {
    const bytes = new Uint8Array([0, 255, 254, 62, 63]);
    const text = toBase64Url(bytes);
    expect(text).not.toMatch(/[+/=]/);
    expect([...fromBase64Url(text)]).toEqual([...bytes]);
    for (const bad of ['a+b', 'a/b', 'a=b', 'a b', '']) expect(() => fromBase64Url(bad)).toThrow();
  });
});

describe('requestAssertion', () => {
  const asBuf = (a: number[]) => new Uint8Array(a).buffer;
  it('is unsupported without WebAuthn', async () => {
    expect(await requestAssertion(options, undefined)).toEqual({
      ok: false,
      reason: 'unsupported',
    });
  });

  it('builds the wire body and sends a discoverable-login request', async () => {
    (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential = class {};
    let seen: CredentialRequestOptions | undefined;
    const out = await requestAssertion(options, {
      get: async (o?: CredentialRequestOptions) => {
        seen = o;
        return {
          id: 'cred',
          rawId: asBuf([9, 8]),
          type: 'public-key',
          response: {
            authenticatorData: asBuf([1]),
            clientDataJSON: asBuf([2]),
            signature: asBuf([3]),
            userHandle: asBuf([]),
          },
        } as unknown as Credential;
      },
    });
    expect(seen?.publicKey?.rpId).toBe('admin.example.test');
    expect(seen?.publicKey?.userVerification).toBe('required');
    expect(seen?.publicKey?.allowCredentials).toEqual([]);
    expect([...new Uint8Array(seen!.publicKey!.challenge as ArrayBuffer)]).toEqual([
      1, 2, 3, 250, 251, 252,
    ]);
    expect(out.ok && out.body.credential.rawId).toBe(toBase64Url(new Uint8Array([9, 8])));
    expect(out.ok && 'userHandle' in out.body.credential.response).toBe(false); // empty handle omitted
  });

  it('maps errors', async () => {
    (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential = class {};
    const throwing = (name: string) => ({
      get: async () => {
        throw Object.assign(new Error('x'), { name });
      },
    });
    expect(await requestAssertion(options, throwing('NotAllowedError'))).toEqual({
      ok: false,
      reason: 'cancelled',
    });
    expect(await requestAssertion(options, throwing('SecurityError'))).toEqual({
      ok: false,
      reason: 'failed',
    });
    expect(await requestAssertion(options, { get: async () => null })).toEqual({
      ok: false,
      reason: 'failed',
    });
  });
});

describe('createCredential', () => {
  const creation: CreationOptions = {
    challengeId: 'c9',
    publicKey: {
      challenge: toBase64Url(new Uint8Array([9, 8, 7])),
      rp: { id: 'admin.example.test', name: 'x' },
      user: { id: toBase64Url(new Uint8Array([1, 2])), name: 'u', displayName: 'u' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      timeout: 1,
      attestation: 'none',
      authenticatorSelection: {
        residentKey: 'required',
        requireResidentKey: true,
        userVerification: 'required',
      },
      excludeCredentials: [{ type: 'public-key', id: toBase64Url(new Uint8Array([5])) }],
    },
    expiresAt: 'e',
  };
  const buf = (a: number[]) => new Uint8Array(a).buffer;

  it('passes decoded binary options and returns the wire body', async () => {
    (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential = class {};
    let seen: CredentialCreationOptions | undefined;
    const out = await createCredential(creation, {
      create: async (o?: CredentialCreationOptions) => {
        seen = o;
        return {
          id: 'cid',
          rawId: buf([4, 5]),
          type: 'public-key',
          response: { attestationObject: buf([1]), clientDataJSON: buf([2]) },
        } as unknown as Credential;
      },
    });
    expect([...new Uint8Array(seen!.publicKey!.challenge as ArrayBuffer)]).toEqual([9, 8, 7]);
    expect([...new Uint8Array(seen!.publicKey!.user.id as ArrayBuffer)]).toEqual([1, 2]);
    expect([...new Uint8Array(seen!.publicKey!.excludeCredentials![0]!.id as ArrayBuffer)]).toEqual(
      [5],
    );
    expect(out.ok && out.body.credential.rawId).toBe(toBase64Url(new Uint8Array([4, 5])));
  });

  it('maps errors', async () => {
    (globalThis as { PublicKeyCredential?: unknown }).PublicKeyCredential = class {};
    const throwing = (name: string) => ({
      create: async () => {
        throw Object.assign(new Error('x'), { name });
      },
    });
    expect(await createCredential(creation, undefined)).toEqual({
      ok: false,
      reason: 'unsupported',
    });
    expect(await createCredential(creation, throwing('NotAllowedError'))).toEqual({
      ok: false,
      reason: 'cancelled',
    });
    expect(await createCredential(creation, throwing('InvalidStateError'))).toEqual({
      ok: false,
      reason: 'duplicate',
    });
    expect(await createCredential(creation, throwing('SecurityError'))).toEqual({
      ok: false,
      reason: 'failed',
    });
    expect(await createCredential(creation, { create: async () => null })).toEqual({
      ok: false,
      reason: 'failed',
    });
  });
});
