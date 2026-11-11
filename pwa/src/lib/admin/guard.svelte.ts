import { session } from '../session.svelte';
import { router } from '../router.svelte';
import type { ApiError } from '../api/client';
import { needsFreshLogin } from './describe';
import { setReauthHandler } from '../api/http';

/** Sends the user to a fresh passkey confirmation (asked for directly) and back to `returnTo`; the draft stays on the server. */
let reauthRunning: Promise<void> | null = null;
export function reauthenticate(returnTo: string): Promise<void> {
  // Several parallel calls (polling, button) must lead to exactly one login detour.
  if (window.location.pathname.startsWith('/login')) return Promise.resolve();
  reauthRunning ??= (async () => {
    await session.logout();
    router.navigate(`/login?next=${encodeURIComponent(returnTo)}&reauth=1`);
  })().finally(() => {
    setTimeout(() => (reauthRunning = null), 10_000);
  });
  return reauthRunning;
}

// Any admin call that hits an expired confirmation is handled here, so no page can end up with a bare 403.
setReauthHandler(async () => {
  await reauthenticate(window.location.pathname + window.location.search);
  return false;
});

/** Handles the failures every page shares. Returns true when the error was consumed (page must stop). */
export function handleSessionError(e: ApiError): boolean {
  if (e.kind === 'http' && e.status === 401 && !needsFreshLogin(e)) {
    session.expired();
    return true;
  }
  return false;
}
