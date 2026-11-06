import { session } from '../session.svelte';
import { router } from '../router.svelte';
import type { ApiError } from '../api/client';
import { needsFreshLogin } from './describe';

/** Sends the user to a fresh login and back to `returnTo`; the draft stays on the server. */
export async function reauthenticate(returnTo: string): Promise<void> {
  await session.logout();
  router.navigate(`/login?next=${encodeURIComponent(returnTo)}`);
}

/** Handles the failures every page shares. Returns true when the error was consumed (page must stop). */
export function handleSessionError(e: ApiError): boolean {
  if (e.kind === 'http' && e.status === 401 && !needsFreshLogin(e)) {
    session.expired();
    return true;
  }
  return false;
}
