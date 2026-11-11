import { createHttp, type Http, type HttpOptions, type Method } from './http';
import type {
  CreationOptions,
  PasskeyCredentialBody,
  PasskeyOptions,
  RegistrationBody,
} from './webauthn';

export type SessionStateName = 'anonymous' | 'factor_pending' | 'authenticated';

export interface SessionState {
  state: SessionStateName;
  secondFactorRequired?: boolean;
  totpAllowed?: boolean;
  csrfToken: string;
  subjectId?: string;
  expiresAt: string;
}

export interface ReauthResult {
  status: 'fresh';
  authenticatedAt: string;
  freshUntil: string;
}

export interface AuthApiOptions extends HttpOptions {
  /** Share one transport (and thus one CSRF token) with the admin API. */
  http?: Http;
}

/** Auth part of the admin API. The CSRF token of the current session is kept in memory only (never stored). */
export function createAuthApi(options: AuthApiOptions = {}) {
  const http = options.http ?? createHttp(options);
  const call = <T>(method: Method, path: string, body?: unknown, signal?: AbortSignal) =>
    http.request<T>(method, path, {
      ...(body !== undefined ? { body } : {}),
      ...(signal ? { signal } : {}),
    });

  return {
    session: (signal?: AbortSignal) =>
      call<SessionState>('GET', '/auth/session', undefined, signal),
    passkeyOptions: (signal?: AbortSignal) =>
      call<PasskeyOptions>('POST', '/auth/passkey/options', undefined, signal),
    passkeyVerify: (body: PasskeyCredentialBody, signal?: AbortSignal) =>
      call<SessionState>('POST', '/auth/passkey/verify', body, signal),
    secondFactorPassword: (password: string, signal?: AbortSignal) =>
      call<SessionState>(
        'POST',
        '/auth/second-factor/password',
        { method: 'password', password },
        signal,
      ),
    totp: (body: { username?: string; password?: string; code: string }) =>
      call<SessionState>('POST', '/auth/totp', body),
    enrollmentOptions: (token: string, signal?: AbortSignal) =>
      call<CreationOptions>('POST', '/auth/enrollment/options', { token }, signal),
    enrollmentVerify: (body: RegistrationBody, signal?: AbortSignal) =>
      call<{ status: string }>('POST', '/auth/enrollment/verify', body, signal),
    /** Adds a passkey to the signed-in account (fresh authentication required). */
    addPasskeyOptions: (signal?: AbortSignal) =>
      call<CreationOptions>('POST', '/auth/passkeys/options', undefined, signal),
    addPasskeyVerify: (body: RegistrationBody, signal?: AbortSignal) =>
      call<{ status: string }>('POST', '/auth/passkeys/verify', body, signal),
    /** Step-up (ADR 0037): renews the fresh authentication of this session with a passkey; no new token. */
    reauthOptions: (signal?: AbortSignal) =>
      call<PasskeyOptions>('POST', '/auth/reauth/options', undefined, signal),
    reauthVerify: (body: PasskeyCredentialBody, signal?: AbortSignal) =>
      call<ReauthResult>('POST', '/auth/reauth/verify', body, signal),
    logout: (signal?: AbortSignal) => call<void>('POST', '/auth/logout', undefined, signal),
  };
}

export type AuthApi = ReturnType<typeof createAuthApi>;
