// SPDX-License-Identifier: AGPL-3.0-only
// State of the setup flow: facts loaded from the API, postponed steps (this browser) and the step context that
// survives navigation and reload (sessionStorage). Nothing here is persisted on the server except what the existing
// settings contract stores (`setup.completed`).
import { adminApi, http } from '$lib/api';
import { session } from '$lib/session.svelte';
import {
  deriveSteps,
  emptyFacts,
  isStepId,
  progressOf,
  STEP_IDS,
  type EntryFacts,
  type Facts,
  type FormFacts,
  type StepId,
} from './onboarding';

interface SettingsSnapshot {
  revision: string;
  items: { definition: { key: string }; value?: string; source?: string }[];
}
interface SetupState {
  required: boolean;
  migrationAllowed?: boolean;
  migrationEnabled?: boolean;
}

/** At most this many customers are asked for their forms. */
const FORM_TENANT_LIMIT = 10;
/** At most this many published forms are asked for submissions. */
const ENTRY_FORM_LIMIT = 8;
/** API tokens count seconds since 2001-01-01 (Apple reference date). */
const REFERENCE_OFFSET = 978307200;
interface TokenRow {
  expires_at: number;
  revoked_at: number | null;
}
const CONTEXT_KEY = 'setup.context';
const skippedKey = (owner: string) => `setup.skipped.${owner}`;

type Deps = { http: Pick<typeof http, 'request'>; adminApi: typeof adminApi };

/** Loads the facts for the given steps (all when omitted); failures stay `null`, never a guess. */
export async function loadFacts(
  deps: Deps,
  which: readonly StepId[],
  state: SetupState,
  signedIn: boolean,
): Promise<{ facts: Partial<Facts>; revision?: string }> {
  const want = (id: StepId) => which.includes(id);
  const facts: Partial<Facts> = {};
  let revision: string | undefined;
  const jobs: Promise<void>[] = [];
  if (want('account')) facts.account = signedIn;
  if (want('recovery'))
    jobs.push(
      deps.adminApi.keyBundle().then((r) => {
        facts.recovery = r.ok ? !!r.data.recovery : null;
      }),
    );
  if (want('mail'))
    jobs.push(
      deps.adminApi.connections().then((r) => {
        facts.mail =
          r.ok && Array.isArray(r.data.items) ? r.data.items.filter((c) => c.enabled).length : null;
      }),
    );
  if (want('addresses'))
    jobs.push(
      deps.http.request<SettingsSnapshot>('GET', '/settings').then((r) => {
        if (!r.ok) return void (facts.addresses = null);
        revision = r.data.revision;
        const set = (key: string) => {
          const item = r.data.items.find((i) => i.definition.key === key);
          return !!item && ((item.value ?? '') !== '' || item.source === 'env');
        };
        facts.addresses = set('admin.origin') && set('admin.rpID');
      }),
    );
  if (want('passkeys'))
    jobs.push(
      deps.adminApi.passkeys().then((r) => {
        facts.passkeys = r.ok && Array.isArray(r.data.items) ? r.data.items.length : null;
      }),
    );
  if (want('token'))
    jobs.push(
      deps.http.request<{ items: TokenRow[] }>('GET', '/account/tokens').then((r) => {
        const now = Date.now() / 1000 - REFERENCE_OFFSET;
        facts.tokens =
          r.ok && Array.isArray(r.data.items)
            ? r.data.items.filter((x) => x.revoked_at == null && x.expires_at > now).length
            : null;
      }),
    );
  const needForms = want('form') || want('testEntry');
  if (want('customer') || needForms)
    jobs.push(
      deps.adminApi.tenants().then(async (r) => {
        if (!r.ok || !Array.isArray(r.data.items)) {
          if (want('customer')) facts.customers = null;
          if (want('form')) facts.forms = null;
          if (want('testEntry')) facts.testEntries = null;
          return;
        }
        if (want('customer')) facts.customers = r.data.items.length;
        if (needForms) {
          const forms = await loadForms(
            deps,
            r.data.items.map((x) => x.id),
          );
          if (want('form')) facts.forms = forms;
          if (want('testEntry')) facts.testEntries = forms ? await loadEntries(deps, forms) : null;
        }
      }),
    );
  if (want('migration')) {
    const available = state.migrationAllowed === true && state.migrationEnabled === true;
    facts.migration = { available, jobs: null };
    if (available)
      jobs.push(
        deps.http.request<{ items: unknown[] }>('GET', '/migration/jobs').then((r) => {
          facts.migration = {
            available,
            jobs: r.ok && Array.isArray(r.data.items) ? r.data.items.length : null,
          };
        }),
      );
  }
  await Promise.all(jobs);
  return revision === undefined ? { facts } : { facts, revision };
}

async function loadForms(deps: Deps, tenants: string[]): Promise<FormFacts | null> {
  const results = await Promise.all(
    tenants.slice(0, FORM_TENANT_LIMIT).map(async (tenant) => ({
      tenant,
      r: await deps.adminApi.forms(tenant),
    })),
  );
  const out: FormFacts = { total: 0, published: 0 };
  let failed = false;
  for (const { tenant, r } of results) {
    if (!r.ok || !Array.isArray(r.data.items)) {
      failed = true;
      continue;
    }
    for (const form of r.data.items) {
      out.total += 1;
      if (form.currentReleaseId) {
        out.published += 1;
        (out.publishedForms ??= []).push({ tenant, form: form.id });
      } else if (!out.unpublished) out.unpublished = { tenant, form: form.id };
    }
  }
  // A failed list may hide the very form that proves the step: unknown, not "open".
  return failed && out.published === 0 ? null : out;
}

/** Asks published forms for submissions; null when a failed list could hide the proof. */
async function loadEntries(deps: Deps, forms: FormFacts): Promise<EntryFacts | null> {
  const list = (forms.publishedForms ?? []).slice(0, ENTRY_FORM_LIMIT);
  if (list.length === 0) return { checked: 0 };
  const results = await Promise.all(
    list.map(async (target) => ({
      target,
      r: await deps.adminApi.entries(target.tenant, target.form),
    })),
  );
  const out: EntryFacts = { checked: list.length, first: list[0] };
  let failed = false;
  for (const { target, r } of results) {
    if (!r.ok || !Array.isArray(r.data.items)) failed = true;
    else if (r.data.items.length > 0 && !out.withEntries) out.withEntries = target;
  }
  return failed && !out.withEntries ? null : out;
}

function read(storage: () => Storage, key: string): string | null {
  try {
    return storage().getItem(key);
  } catch {
    return null;
  }
}
function write(storage: () => Storage, key: string, value: string | null): void {
  try {
    if (value === null) storage().removeItem(key);
    else storage().setItem(key, value);
  } catch {
    /* Storage may be blocked; the flow still works for this page view. */
  }
}

class Onboarding {
  /** null until the first answer. */
  required = $state<boolean | null>(null);
  facts = $state<Facts>({ ...emptyFacts });
  loading = $state(false);
  /** The facts of all steps have been loaded once (before that every step would look like an error). */
  ready = $state(false);
  /** The setup state itself could not be read. */
  failed = $state(false);
  revision = $state('');
  private skipped = $state<StepId[]>([]);
  private context = $state<StepId | null>(null);
  private setupState: SetupState = { required: false };
  private owner: string | null = null;
  private run = 0;

  constructor(private readonly deps: Deps = { http, adminApi }) {
    const stored = read(() => sessionStorage, CONTEXT_KEY);
    this.context = isStepId(stored) ? stored : null;
  }

  readonly steps = $derived(deriveSteps(this.facts, this.skipped));
  readonly progress = $derived(progressOf(this.steps));
  /** Setup still open for this account (needs the system right; the server decides). */
  get open(): boolean {
    return this.required === true;
  }
  get activeContext(): StepId | null {
    return this.context;
  }

  private bind(): void {
    const owner = session.me?.id ?? null;
    if (owner === this.owner) return;
    this.owner = owner;
    const raw = owner ? read(() => localStorage, skippedKey(owner)) : null;
    try {
      const parsed: unknown = raw ? JSON.parse(raw) : [];
      this.skipped = Array.isArray(parsed) ? parsed.filter(isStepId) : [];
    } catch {
      this.skipped = [];
    }
  }

  /** Loads the setup state, then the facts of all steps. */
  async load(which?: readonly StepId[]): Promise<void> {
    const run = ++this.run;
    this.bind();
    this.loading = true;
    if (!which) {
      const s = await this.deps.http.request<SetupState>('GET', '/setup-state');
      if (run !== this.run) return;
      this.failed = !s.ok;
      if (!s.ok) {
        this.loading = false;
        return;
      }
      this.setupState = s.data;
      this.required = s.data.required;
      if (!s.data.required) {
        this.loading = false;
        return;
      }
    }
    const ids = which ?? STEP_IDS;
    const loaded = await loadFacts(this.deps, ids, this.setupState, session.status === 'ready');
    if (run !== this.run) return;
    this.facts = { ...this.facts, ...loaded.facts };
    if (loaded.revision !== undefined) this.revision = loaded.revision;
    if (!which) this.ready = true;
    this.loading = false;
  }

  /** Re-checks only what one step depends on (cheap, used while a target page is open). */
  async refreshStep(id: StepId): Promise<void> {
    if (this.required !== true) return;
    const which: StepId[] =
      id === 'customer'
        ? ['customer', 'form', 'testEntry']
        : id === 'form'
          ? ['form', 'testEntry']
          : [id];
    const loaded = await loadFacts(this.deps, which, this.setupState, session.status === 'ready');
    this.facts = { ...this.facts, ...loaded.facts };
    if (loaded.revision !== undefined) this.revision = loaded.revision;
  }

  skip(id: StepId): void {
    if (!this.skipped.includes(id)) this.skipped = [...this.skipped, id];
    this.saveSkipped();
  }
  resume(id: StepId): void {
    this.skipped = this.skipped.filter((s) => s !== id);
    this.saveSkipped();
  }
  private saveSkipped(): void {
    if (this.owner) write(() => localStorage, skippedKey(this.owner), JSON.stringify(this.skipped));
  }

  /** Remembers which step the user is working on while visiting another page. */
  setContext(id: StepId | null): void {
    this.context = id;
    write(() => sessionStorage, CONTEXT_KEY, id);
  }

  markFinished(): void {
    this.required = false;
    this.setContext(null);
  }

  /** Test helper and sign-out: forget everything of the previous account. */
  reset(): void {
    this.run++;
    this.required = null;
    this.ready = false;
    this.facts = { ...emptyFacts };
    this.skipped = [];
    this.owner = null;
    this.failed = false;
    this.setContext(null);
  }
}

export const onboarding = new Onboarding();
export { Onboarding };
