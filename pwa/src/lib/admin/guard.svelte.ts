import { session } from '../session.svelte';
import { router } from '../router.svelte';
import type { ApiError } from '../api/client';
import { needsFreshLogin } from './describe';
import { setReauthHandler } from '../api/http';
import { authApi } from '../api';
import { requestAssertion } from '../api/webauthn';
import { createStepUp } from './stepup.svelte';

/** The one step-up controller of the app; ReauthDialog renders it (ADR 0037). */
export const stepUp = createStepUp({
  options: () => authApi.reauthOptions(),
  verify: (body) => authApi.reauthVerify(body),
  // The step-up only needs the signature; no PRF/key material is requested.
  assertion: (options) => requestAssertion(options, undefined, { prf: false }),
  supported: () =>
    typeof window !== 'undefined' &&
    typeof PublicKeyCredential !== 'undefined' &&
    typeof navigator !== 'undefined' &&
    !!navigator.credentials,
});

/** Full detour: ends the session and runs the login again, then returns to `returnTo` (the draft stays on the server). */
let fullLoginRunning: Promise<void> | null = null;
export function fullLogin(returnTo: string): Promise<void> {
  // Several parallel calls (polling, button) must lead to exactly one login detour.
  if (window.location.pathname.startsWith('/login')) return Promise.resolve();
  fullLoginRunning ??= (async () => {
    await session.logout();
    router.navigate(`/login?next=${encodeURIComponent(returnTo)}&reauth=1`);
  })().finally(() => {
    setTimeout(() => (fullLoginRunning = null), 10_000);
  });
  return fullLoginRunning;
}

const here = () => window.location.pathname + window.location.search;

/**
 * For pages that still react to `reauthentication_required` themselves (and for explicit "Mit Passkey bestätigen" buttons).
 * The failed call has already passed the central handler below, so nothing happens when a step-up just ended or the user
 * cancelled and has not acted since; otherwise the same dialog opens (or the full login runs as fallback).
 */
export async function reauthenticate(returnTo: string): Promise<void> {
  if (stepUp.settledWithin()) return;
  const result = await stepUp.request();
  if (result === 'fallback') await fullLogin(returnTo);
}

// Any admin call that hits an expired confirmation is handled here, so no page can end up with a bare 403:
// the passkey dialog on the current page, and on success the call is retried once (lib/api/http.ts).
setReauthHandler(async () => {
  const result = await stepUp.request();
  if (result === 'fallback') await fullLogin(here());
  return result === 'confirmed';
});

/** Handles the failures every page shares. Returns true when the error was consumed (page must stop). */
export function handleSessionError(e: ApiError): boolean {
  if (e.kind === 'http' && e.status === 401 && !needsFreshLogin(e)) {
    session.expired();
    return true;
  }
  return false;
}
