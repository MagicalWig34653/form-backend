import { t } from '../i18n';
import type { ApiError } from '../api/client';

/** 429: names the wait from `Retry-After` when the server sent one. */
export function rateLimitText(e: ApiError): string {
  const a = t.admin.errors;
  return e.retryAfter !== undefined
    ? a.tooManyWait.replace('{seconds}', String(e.retryAfter))
    : a.tooMany;
}

/** Text for a failed load: the rate-limit message for 429, otherwise the page's own `fallback`. */
export function loadFailureText(e: ApiError, fallback: string): string {
  return e.kind === 'http' && e.status === 429 ? rateLimitText(e) : fallback;
}

/** German, user-facing text for a failed admin call. The server's own fixed message is appended for validation errors. */
export function describeError(e: ApiError): string {
  const a = t.admin.errors;
  if (e.kind !== 'http') return e.message;
  switch (e.status) {
    case 401:
      return a.unauthenticated;
    case 403:
      return e.code === 'reauthentication_required' ? a.reauth : a.forbidden;
    case 404:
      return a.notFound;
    case 409:
      if (e.code === 'version_exists') return a.versionExists;
      // Retention problems carry their own fixed German reason (server: retention_missing / retention_import_running).
      return e.code?.startsWith('retention_') && e.detail ? e.detail : a.conflict;
    case 412:
      return a.stale;
    case 422:
      return e.detail ? `${a.invalid} ${e.detail}` : a.invalid;
    case 429:
      return rateLimitText(e);
    default:
      return a.generic;
  }
}

/** The server answers an expired fresh login with 403 `reauthentication_required` (older drafts used 401). */
export const needsFreshLogin = (e: ApiError): boolean =>
  e.kind === 'http' &&
  (e.status === 403 || e.status === 401) &&
  e.code === 'reauthentication_required';
