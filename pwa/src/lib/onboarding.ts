// SPDX-License-Identifier: AGPL-3.0-only
// Setup checklist derived from real data. A step is "done" only when the data proves it; anything that could not be
// loaded is "error", never guessed. Pure functions: the store (onboarding.svelte.ts) fetches the facts.
import type { Route } from './routes';

/** Working order. Stored "skipped" values are keyed by id, so reordering never invalidates them. */
export const STEP_IDS = [
  'account',
  'recovery',
  'passkeys',
  'addresses',
  'mail',
  'customer',
  'form',
  'token',
  'testEntry',
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
  /** Number of passkeys of the signed-in account. */
  passkeys: number | null;
  /** Number of API tokens that are neither revoked nor expired. */
  tokens: number | null;
  /** Submissions found in published forms. */
  testEntries: EntryFacts | null;
  /** Import runs; `available: false` hides the step (no right or switched off). */
  migration: { available: boolean; jobs: number | null; status: MigrationStatus | null };
}
/**
 * What the import runs prove: `imported` = a real (non-dry) run reached review/verified/closed; `dryRun` = only a dry run finished;
 * `running` = a run is queued/running/paused; `none` = nothing usable yet.
 */
export type MigrationStatus = 'none' | 'running' | 'dryRun' | 'imported';
export interface FormFacts {
  total: number;
  published: number;
  /** First form that still lacks a release (target of "publish"). */
  unpublished?: { tenant: string; form: string };
  /** Published forms (bounded), where a test submission can be checked. */
  publishedForms?: { tenant: string; form: string }[];
}
export interface EntryFacts {
  /** Published forms that were asked. */
  checked: number;
  /** Form holding at least one submission (target of the entries link). */
  withEntries?: { tenant: string; form: string };
  /** Entries of the first published form, used as target when none has any yet. */
  first?: { tenant: string; form: string };
}

export interface Step {
  id: StepId;
  state: StepState;
  /** Optional steps can be postponed ("Später"). */
  skippable: boolean;
  /** Marked "optional" in the list. */
  optional: boolean;
  /** Extra situation that changes the wording of an open step. */
  detail?: 'draftOnly' | 'needsCustomer' | 'needsPublished' | 'imported' | 'dryRun' | 'running';
}

export const emptyFacts: Facts = {
  account: null,
  recovery: null,
  mail: null,
  addresses: null,
  customers: null,
  forms: null,
  passkeys: null,
  tokens: null,
  testEntries: null,
  migration: { available: false, jobs: null, status: null },
};

/** Steps whose absence blocks finishing; everything else may be postponed. */
const REQUIRED: readonly StepId[] = ['account', 'recovery'];
/** Steps that are explicitly optional (marked as such in the list). */
export const OPTIONAL: readonly StepId[] = ['passkeys', 'token', 'testEntry', 'migration'];
/** Passkeys needed so that losing one device does not lock the account out. */
export const PASSKEYS_WANTED = 2;

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
    case 'passkeys':
      return f.passkeys === null ? null : f.passkeys >= PASSKEYS_WANTED;
    case 'token':
      return f.tokens === null ? null : f.tokens > 0;
    case 'testEntry':
      // Without a published form there can be no proof; with unknown form data nothing is known.
      if (f.forms === null) return null;
      if (f.forms.published === 0) return false;
      return f.testEntries === null ? null : !!f.testEntries.withEntries;
    case 'migration':
      return f.migration.status === null ? null : f.migration.status === 'imported';
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
    const step: Step = { id, state, skippable, optional: OPTIONAL.includes(id) };
    if (id === 'form' && state === 'open' && facts.forms) {
      if ((facts.customers ?? 0) === 0) step.detail = 'needsCustomer';
      else if (facts.forms.total > 0) step.detail = 'draftOnly';
    }
    // Imported customers are active (finding A, 13.11.2026) and normally make this step done. Still open after an import means the
    // account sees none of them (rights): say that a customer was imported instead of offering "first customer".
    if (id === 'customer' && state === 'open' && facts.migration.status === 'imported')
      step.detail = 'imported';
    if (id === 'migration' && state === 'open') {
      if (facts.migration.status === 'dryRun') step.detail = 'dryRun';
      else if (facts.migration.status === 'running') step.detail = 'running';
    }
    if (id === 'testEntry' && state === 'open' && facts.forms?.published === 0)
      step.detail = 'needsPublished';
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
    case 'passkeys':
      return route.name === 'account';
    case 'token':
      return route.name === 'apiTokens';
    case 'testEntry':
      return route.name === 'form' || route.name === 'forms' || route.name === 'formDirectory';
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
