import { t } from '../i18n';

export type ApiErrorKind = 'network' | 'timeout' | 'http' | 'parse' | 'aborted';

export interface ApiError {
  kind: ApiErrorKind;
  /** HTTP status for kind 'http', otherwise undefined. */
  status?: number;
  /** Machine code of the server's problem body (kind 'http'), e.g. authentication_failed. */
  code?: string;
  /** Fixed German text of the server's problem body (e.g. which rule a draft violates). */
  detail?: string;
  /** Seconds from Retry-After (rate limiting). */
  retryAfter?: number;
  /** German, user-facing message. */
  message: string;
}

export type ApiResult<T> = { ok: true; data: T } | { ok: false; error: ApiError };

export interface HealthResponse {
  status: string;
}

export interface ApiClientOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

// Admin API base path per contracts/auth/admin-api.openapi.yaml; override via VITE_API_BASE.
const DEFAULT_BASE: string = import.meta.env.VITE_API_BASE ?? '/admin/api/v1';

function fail(kind: ApiErrorKind, status?: number): { ok: false; error: ApiError } {
  const error: ApiError = { kind, message: t.errors[kind] };
  if (status !== undefined) error.status = status;
  return { ok: false, error };
}

export function createApiClient(options: ApiClientOptions = {}) {
  const baseUrl = options.baseUrl ?? DEFAULT_BASE;
  const timeoutMs = options.timeoutMs ?? 10_000;
  const doFetch = options.fetchImpl ?? ((...args: Parameters<typeof fetch>) => fetch(...args));

  async function get<T>(path: string, signal?: AbortSignal): Promise<ApiResult<T>> {
    const timeout = AbortSignal.timeout(timeoutMs);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    let res: Response;
    try {
      res = await doFetch(`${baseUrl}${path}`, {
        method: 'GET',
        headers: { Accept: 'application/json' },
        cache: 'no-store',
        credentials: 'same-origin',
        signal: combined,
      });
    } catch {
      if (signal?.aborted) return fail('aborted');
      if (timeout.aborted) return fail('timeout');
      return fail('network');
    }
    if (!res.ok) return fail('http', res.status);
    try {
      return { ok: true, data: (await res.json()) as T };
    } catch {
      // Abort/timeout can also hit while the body is still streaming.
      if (signal?.aborted) return fail('aborted');
      if (timeout.aborted) return fail('timeout');
      return fail('parse');
    }
  }

  return {
    health: (signal?: AbortSignal) => get<HealthResponse>('/health', signal),
  };
}

export type ApiClient = ReturnType<typeof createApiClient>;
