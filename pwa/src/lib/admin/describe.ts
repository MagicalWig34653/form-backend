import { t } from '../i18n';
import type { ApiError } from '../api/client';

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
      return a.conflict;
    case 412:
      return a.stale;
    case 422:
      return e.detail ? `${a.invalid} ${e.detail}` : a.invalid;
    case 429:
      return a.tooMany;
    default:
      return a.generic;
  }
}

/** The server answers an expired fresh login with 403 `reauthentication_required` (older drafts used 401). */
export const needsFreshLogin = (e: ApiError): boolean =>
  e.kind === 'http' &&
  (e.status === 403 || e.status === 401) &&
  e.code === 'reauthentication_required';
