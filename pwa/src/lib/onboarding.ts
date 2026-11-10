// SPDX-License-Identifier: AGPL-3.0-only
// Setup checklist derived from real data. A step is "done" only when the data proves it; anything that could not be
// loaded is "error", never guessed. Pure functions: the store (onboarding.svelte.ts) fetches the facts.
import type { Route } from './routes';

export const STEP_IDS = [
  'account',
  'recovery',
  'mail',
  'addresses',
  'customer',
  'form',
  'migration',
] as const;
export type StepId = (typeof STEP_IDS)[number];
export type StepState = 'done' | 'open' | 'skipped' | 'error';

/** What the data says. `null` = could not be determined (request failed). */
export interface Facts {
  /** Signed in with a valid session. */
  account: boolean | null;
  /** The account recovery code exists on the server. */
  recovery: boolean | null;
  /** Number of enabled mail connections. */
  mail: number | null;
  /** Public origin and RP ID are set (environment or database). */
  addresses: boolean | null;
  /** Number of customers visible to the account. */
  customers: number | null;
  forms: FormFacts | null;
  /** Import runs; `available: false` hides the step (no right or switched off). */
  migration: { available: boolean; jobs: number | null };
}
export interface FormFacts {
  total: number;
  published: number;
  /** First form that still lacks a release (target of "publish"). */
  unpublished?: { tenant: string; form: string };
}

export interface Step {
  id: StepId;
  state: StepState;
  /** Optional steps can be postponed ("Später"). */
  skippable: boolean;
  /** Extra situation that changes the wording of an open step. */
  detail?: 'draftOnly' | 'needsCustomer';
}

export const emptyFacts: Facts = {
  account: null,
  recovery: null,
  mail: null,
  addresses: null,
  customers: null,
  forms: null,
  migration: { available: false, jobs: null },
};

/** Steps whose absence blocks finishing; everything else may be postponed. */
const REQUIRED: readonly StepId[] = ['account', 'recovery'];

function doneOf(id: StepId, f: Facts): boolean | null {
  switch (id) {
    case 'account':
      return f.account;
    case 'recovery':
      return f.recovery;
    case 'mail':
      return f.mail === null ? null : f.mail > 0;
    case 'addresses':
      return f.addresses;
    case 'customer':
      return f.customers === null ? null : f.customers > 0;
    case 'form':
      return f.forms === null ? null : f.forms.published > 0;
    case 'migration':
      return f.migration.jobs === null ? null : f.migration.jobs > 0;
  }
}

export function deriveSteps(facts: Facts, skipped: readonly StepId[] = []): Step[] {
  const steps: Step[] = [];
  for (const id of STEP_IDS) {
    if (id === 'migration' && !facts.migration.available) continue;
    const done = doneOf(id, facts);
    const skippable = !REQUIRED.includes(id);
    let state: StepState;
    if (done === true) state = 'done';
    else if (skippable && skipped.includes(id)) state = 'skipped';
    else state = done === null ? 'error' : 'open';
    const step: Step = { id, state, skippable };
    if (id === 'form' && state === 'open' && facts.forms) {
      if ((facts.customers ?? 0) === 0) step.detail = 'needsCustomer';
      else if (facts.forms.total > 0) step.detail = 'draftOnly';
    }
    steps.push(step);
  }
  return steps;
}

export interface Progress {
  /** Steps handled: done or postponed. */
  handled: number;
  done: number;
  total: number;
  /** Index of the first step still needing attention, -1 when none. */
  current: number;
  /** Nothing open or failing; the setup may be finished. */
  complete: boolean;
}
export function progressOf(steps: readonly Step[]): Progress {
  const done = steps.filter((s) => s.state === 'done').length;
  const handled = steps.filter((s) => s.state === 'done' || s.state === 'skipped').length;
  const current = steps.findIndex((s) => s.state === 'open' || s.state === 'error');
  return { handled, done, total: steps.length, current, complete: current === -1 };
}

/** The step after `id` that still needs attention (wrapping to earlier ones), null when none. */
export function nextOpenStep(steps: readonly Step[], id: StepId): Step | null {
  const at = steps.findIndex((s) => s.id === id);
  const needs = (s: Step) => s.state === 'open' || s.state === 'error';
  return steps.slice(at + 1).find(needs) ?? steps.slice(0, Math.max(at, 0)).find(needs) ?? null;
}

/** Pages a step may send the user to; the setup bar stays only on these. */
export function stepScope(id: StepId, route: Route): boolean {
  switch (id) {
    case 'account':
    case 'recovery':
      return route.name === 'account';
    case 'mail':
      return route.name === 'connections';
    case 'addresses':
      return route.name === 'settings';
    case 'migration':
      return route.name === 'migration';
    case 'customer':
      return route.name === 'tenants' || route.name === 'forms';
    case 'form':
      return route.name === 'form' || route.name === 'forms' || route.name === 'formDirectory';
  }
}

export function isStepId(value: unknown): value is StepId {
  return typeof value === 'string' && (STEP_IDS as readonly string[]).includes(value);
}
