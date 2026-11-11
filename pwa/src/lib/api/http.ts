import { t } from '../i18n';
import type { ApiError, ApiErrorKind, ApiResult } from './client';

export interface HttpOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export interface RequestOptions {
  body?: unknown;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

export type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface Http {
  request<T>(method: Method, path: string, options?: RequestOptions): Promise<ApiResult<T>>;
  /** CSRF token of the current session (memory only, never stored). */
  readonly csrf: string | undefined;
}

// Admin API base path per contracts/auth/admin-api.openapi.yaml; override via VITE_API_BASE.
export const DEFAULT_BASE: string = import.meta.env.VITE_API_BASE ?? '/admin/api/v1';

function fail(
  kind: ApiErrorKind,
  status?: number,
  code?: string,
  retryAfter?: number,
  detail?: string,
): { ok: false; error: ApiError } {
  const error: ApiError = { kind, message: t.errors[kind] };
  if (status !== undefined) error.status = status;
  if (code !== undefined) error.code = code;
  if (retryAfter !== undefined) error.retryAfter = retryAfter;
  if (detail !== undefined) error.detail = detail;
  return { ok: false, error };
}

type ReauthHandler = () => Promise<boolean>;
let reauthHandler: ReauthHandler | undefined;
/** Called when the server demands a fresh confirmation (403 reauthentication_required); true = confirmed, retry the call once. */
export function setReauthHandler(handler: ReauthHandler | undefined): void {
  reauthHandler = handler;
}
const needsConfirmation = (e: ApiError): boolean =>
  e.kind === 'http' &&
  (e.status === 403 || e.status === 401) &&
  e.code === 'reauthentication_required';

/** One transport for every admin call: same-origin cookie, CSRF on mutations, no caching, bounded time, uniform errors. */
export function createHttp(options: HttpOptions = {}): Http {
  const baseUrl = options.baseUrl ?? DEFAULT_BASE;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const doFetch = options.fetchImpl ?? ((...args: Parameters<typeof fetch>) => fetch(...args));
  let csrf: string | undefined;

  async function request<T>(
    method: Method,
    path: string,
    opts: RequestOptions = {},
  ): Promise<ApiResult<T>> {
    const first = await send<T>(method, path, opts);
    if (!first.ok && needsConfirmation(first.error) && reauthHandler) {
      const confirmed = await reauthHandler().catch(() => false);
      if (confirmed) return send<T>(method, path, opts);
    }
    return first;
  }

  async function send<T>(
    method: Method,
    path: string,
    opts: RequestOptions,
  ): Promise<ApiResult<T>> {
    const timeout = AbortSignal.timeout(timeoutMs);
    const combined = opts.signal ? AbortSignal.any([opts.signal, timeout]) : timeout;
    const headers: Record<string, string> = { Accept: 'application/json', ...opts.headers };
    if (method !== 'GET') {
      if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
      if (csrf) headers['X-CSRF-Token'] = csrf;
    }
    let res: Response;
    try {
      res = await doFetch(`${baseUrl}${path}`, {
        method,
        headers,
        cache: 'no-store',
        credentials: 'same-origin',
        signal: combined,
        ...(opts.body !== undefined ? { body: JSON.stringify(opts.body) } : {}),
      });
    } catch {
      if (opts.signal?.aborted) return fail('aborted');
      if (timeout.aborted) return fail('timeout');
      return fail('network');
    }
    if (!res.ok) {
      let code: string | undefined;
      let detail: string | undefined;
      try {
        const body = (await res.json()) as { code?: string; message?: string };
        code = body.code;
        if (typeof body.message === 'string') detail = body.message.slice(0, 300);
      } catch {
        /* the body is optional */
      }
      const ra = Number(res.headers.get('Retry-After'));
      return fail(
        'http',
        res.status,
        code,
        Number.isInteger(ra) && ra > 0 ? ra : undefined,
        detail,
      );
    }
    if (res.status === 204) return { ok: true, data: undefined as T };
    try {
      const data = (await res.json()) as T;
      const token = (data as { csrfToken?: unknown } | null)?.csrfToken;
      if (typeof token === 'string' && token) csrf = token;
      return { ok: true, data };
    } catch {
      if (opts.signal?.aborted) return fail('aborted');
      if (timeout.aborted) return fail('timeout');
      return fail('parse');
    }
  }

  return {
    request,
    get csrf() {
      return csrf;
    },
  };
}
