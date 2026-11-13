import { SvelteMap } from 'svelte/reactivity';
import { adminApi } from '$lib/api';
import type { AdminApi } from '$lib/api/admin';
import { handleSessionError } from '$lib/admin/guard.svelte';
import { session } from '$lib/session.svelte';
import type { FormListState } from '$lib/area';
import { mapLimited } from '$lib/stats/series';

/** At most this many form-list requests are in flight at once. */
export const LIST_PARALLEL = 4;
/** A cached list is reused for this long. */
export const LIST_TTL_MS = 60_000;

/**
 * Form lists per customer for the area menu and the overall dashboard. Loaded only when needed,
 * cached for a short time, each customer fails on its own (nothing is decrypted).
 */
export class FormLists {
  readonly states = new SvelteMap<string, FormListState>();
  private readonly loadedAt = new SvelteMap<string, number>();
  private readonly inflight = new SvelteMap<string, Promise<void>>();
  private owner: string | null = null;

  constructor(
    private readonly api: Pick<AdminApi, 'forms'> = adminApi,
    private readonly now: () => number = Date.now,
    private readonly onError: (
      e: Parameters<typeof handleSessionError>[0],
    ) => boolean = handleSessionError,
  ) {}

  /** Drops everything when another account is signed in. */
  bind(owner: string | null): void {
    if (this.owner === owner) return;
    this.owner = owner;
    this.clear();
  }
  clear(): void {
    this.states.clear();
    this.loadedAt.clear();
    this.inflight.clear();
  }
  /** Marks a customer's list as outdated, e.g. after a form was created. */
  invalidate(tenant: string): void {
    this.loadedAt.delete(tenant);
  }
  /** Stores a list that a page has just loaded itself. */
  set(tenant: string, items: FormListState['items'], more: boolean): void {
    this.states.set(tenant, { status: 'ready', items, more });
    this.loadedAt.set(tenant, this.now());
  }

  private fresh(tenant: string): boolean {
    const at = this.loadedAt.get(tenant);
    return (
      at !== undefined &&
      this.now() - at < LIST_TTL_MS &&
      this.states.get(tenant)?.status === 'ready'
    );
  }

  load(tenant: string, force = false): Promise<void> {
    if (!force && this.fresh(tenant)) return Promise.resolve();
    const running = this.inflight.get(tenant);
    if (running) return running;
    const old = this.states.get(tenant);
    this.states.set(tenant, {
      status: 'loading',
      items: old?.items ?? [],
      more: old?.more ?? false,
    });
    const job = (async () => {
      try {
        const r = await this.api.forms(tenant);
        if (r.ok) this.set(tenant, r.data.items, Boolean(r.data.nextCursor));
        else {
          this.onError(r.error);
          this.states.set(tenant, { status: 'error', items: [], more: false });
        }
      } catch {
        this.states.set(tenant, { status: 'error', items: [], more: false });
      } finally {
        this.inflight.delete(tenant);
      }
    })();
    this.inflight.set(tenant, job);
    return job;
  }

  /** Loads the lists of the given customers with bounded parallelism; cached ones are skipped. */
  async ensure(tenants: readonly string[], force = false): Promise<void> {
    this.bind(session.me?.id ?? null);
    await mapLimited(tenants, LIST_PARALLEL, (id) => this.load(id, force));
  }
}

export const formLists = new FormLists();
