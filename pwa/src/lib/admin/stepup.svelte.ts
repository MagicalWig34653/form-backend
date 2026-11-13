import type { ApiResult } from '$lib/api/client';
import type { PasskeyCredentialBody, PasskeyOptions, PasskeyOutcome } from '$lib/api/webauthn';

/**
 * Passkey step-up on the current page (ADR 0037): when the server answers 403 `reauthentication_required`, ONE dialog asks for
 * the passkey, renews the session's fresh authentication (POST /auth/reauth/options|verify) and lets the caller retry once.
 * - Parallel requests (polling, buttons) share one dialog and one result.
 * - After "Abbrechen" no dialog opens again until the next user action (no dialog spam from background polling).
 * - `fallback`: the server refuses the step-up (409 second_factor_required, 404 older server, session gone) or the browser has
 *   no passkeys; the caller then runs the full login.
 */
export type StepUpResult = 'confirmed' | 'cancelled' | 'fallback';
export type StepUpError = 'cancelled' | 'failed' | 'rateLimited';
export type StepUpPhase = 'ready' | 'working' | 'error';

export interface StepUpDeps {
  options: () => Promise<ApiResult<PasskeyOptions>>;
  verify: (body: PasskeyCredentialBody) => Promise<ApiResult<unknown>>;
  assertion: (options: PasskeyOptions) => Promise<PasskeyOutcome>;
  /** False when the browser has no WebAuthn at all (then the full login is the only way). */
  supported: () => boolean;
  /** Registers a one-shot "the user did something" callback; returns a disposer. */
  onUserAction?: (callback: () => void) => () => void;
  now?: () => number;
}

const defaultUserAction = (callback: () => void): (() => void) => {
  if (typeof window === 'undefined') return () => {};
  const stop = new AbortController();
  const fire = () => {
    stop.abort();
    callback();
  };
  // Deferred: the click or Escape that cancelled the dialog must not count as the next action.
  const timer = setTimeout(() => {
    window.addEventListener('pointerdown', fire, { capture: true, signal: stop.signal });
    window.addEventListener('keydown', fire, { capture: true, signal: stop.signal });
  }, 0);
  return () => {
    clearTimeout(timer);
    stop.abort();
  };
};

/** Statuses that mean "this server/session cannot step up here": use the full login. */
const isFallback = (r: ApiResult<unknown>): boolean =>
  !r.ok &&
  r.error.kind === 'http' &&
  (r.error.status === 409 ||
    r.error.status === 404 ||
    (r.error.status === 401 && r.error.code !== 'authentication_failed'));

export function createStepUp(deps: StepUpDeps) {
  const now = deps.now ?? (() => Date.now());
  const onUserAction = deps.onUserAction ?? defaultUserAction;
  const state = $state<{ open: boolean; phase: StepUpPhase; error: StepUpError | null }>({
    open: false,
    phase: 'ready',
    error: null,
  });
  let running: Promise<StepUpResult> | null = null;
  let resolveRunning: ((r: StepUpResult) => void) | null = null;
  let suppressed = false;
  let disposeListener: (() => void) | null = null;
  let settledAt = Number.NEGATIVE_INFINITY;
  // Each dialog gets its own generation, so a late answer of a cancelled attempt never touches a newer dialog.
  let generation = 0;

  function finish(result: StepUpResult): void {
    const resolve = resolveRunning;
    state.open = false;
    state.phase = 'ready';
    state.error = null;
    running = null;
    resolveRunning = null;
    settledAt = now();
    if (result === 'cancelled') {
      suppressed = true;
      disposeListener?.();
      disposeListener = onUserAction(() => {
        suppressed = false;
        disposeListener = null;
      });
    }
    resolve?.(result);
  }

  function fail(error: StepUpError): void {
    state.phase = 'error';
    state.error = error;
  }

  return {
    get open() {
      return state.open;
    },
    get phase() {
      return state.phase;
    },
    get error() {
      return state.error;
    },
    /** True while the user has not acted since cancelling: automatic requests must not reopen the dialog. */
    get suppressed() {
      return suppressed;
    },
    /** A step-up ended within `windowMs` (pages that react to the same failed call must not start another). */
    settledWithin(windowMs = 1500): boolean {
      return now() - settledAt < windowMs;
    },
    /** Opens the dialog (or joins the open one) and resolves with the outcome. */
    request(): Promise<StepUpResult> {
      if (running) return running;
      if (suppressed) return Promise.resolve('cancelled');
      if (!deps.supported()) return Promise.resolve('fallback');
      generation += 1;
      state.open = true;
      state.phase = 'ready';
      state.error = null;
      running = new Promise<StepUpResult>((resolve) => (resolveRunning = resolve));
      return running;
    },
    /** The user pressed "Mit Passkey bestätigen" (a user gesture, as WebAuthn needs). */
    async confirm(): Promise<void> {
      if (!state.open || state.phase === 'working') return;
      const mine = generation;
      const live = () => state.open && generation === mine;
      state.phase = 'working';
      state.error = null;
      const options = await deps.options();
      if (!live()) return;
      if (!options.ok) {
        if (isFallback(options)) return finish('fallback');
        return fail(options.error.status === 429 ? 'rateLimited' : 'failed');
      }
      const outcome = await deps.assertion(options.data);
      if (!live()) return;
      if (!outcome.ok) {
        if (outcome.reason === 'unsupported') return finish('fallback');
        return fail(outcome.reason === 'cancelled' ? 'cancelled' : 'failed');
      }
      const verified = await deps.verify(outcome.body);
      if (!live()) return;
      if (verified.ok) return finish('confirmed');
      if (isFallback(verified)) return finish('fallback');
      fail(verified.error.status === 429 ? 'rateLimited' : 'failed');
    },
    /** "Abbrechen", Escape or closing the dialog. */
    cancel(): void {
      if (running) finish('cancelled');
    },
  };
}

export type StepUp = ReturnType<typeof createStepUp>;
