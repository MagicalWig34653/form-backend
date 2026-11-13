import { SvelteMap } from 'svelte/reactivity';
import type { AdminApi, FormListItem } from '$lib/api/admin';
import type { ApiError } from '$lib/api/client';
import { emptySnapshot, type FormSnapshot } from './overview';
import { mapLimited } from './series';

/** At most this many requests are in flight at once. */
export const MAX_PARALLEL = 8;
export const SPARK_DAYS = 14;

type Kind = 'stats' | 'detail' | 'entries';

/**
 * Loads statistics, form detail and the first entry page (metadata only, nothing is decrypted)
 * per form through the existing, permission-checked endpoints. Each request fails on its own.
 */
export class OverviewLoader {
  readonly snapshots = new SvelteMap<string, FormSnapshot>();
  private generation = 0;

  constructor(
    private readonly api: Pick<AdminApi, 'statistics' | 'form' | 'entries'>,
    /** Called with a failed result's error; return true when it was a session problem. */
    private readonly onError: (error: ApiError) => boolean = () => false,
  ) {}

  cancel(): void {
    this.generation++;
  }

  /** One customer. */
  load(tenant: string, forms: FormListItem[]): Promise<void> {
    return this.loadMany([{ tenant, forms }]);
  }

  /** Several customers at once (overall dashboard); the parallelism limit applies to all of them together. */
  async loadMany(groups: { tenant: string; forms: FormListItem[] }[]): Promise<void> {
    const current = ++this.generation;
    const all = groups.flatMap((g) => g.forms.map((f) => ({ tenant: g.tenant, id: f.id })));
    for (const id of [...this.snapshots.keys()])
      if (!all.some((f) => f.id === id)) this.snapshots.delete(id);
    for (const f of all) this.snapshots.set(f.id, emptySnapshot());
    const kinds: Kind[] = ['stats', 'detail', 'entries'];
    // Statistics for every form first so the tiles fill early.
    const tasks = kinds.flatMap((kind) => all.map((f) => ({ kind, ...f })));
    await mapLimited(tasks, MAX_PARALLEL, async (task) => {
      if (this.generation !== current) return;
      const patch = await this.run(task.tenant, task.kind, task.id);
      if (this.generation !== current) return;
      const old = this.snapshots.get(task.id);
      if (old) this.snapshots.set(task.id, { ...old, ...patch });
    });
  }

  private async run(tenant: string, kind: Kind, id: string): Promise<Partial<FormSnapshot>> {
    try {
      if (kind === 'stats') {
        const r = await this.api.statistics(tenant, id, SPARK_DAYS);
        if (r.ok) return { stats: r.data, statsStatus: 'ready' };
        this.onError(r.error);
        return { statsStatus: 'error' };
      }
      if (kind === 'detail') {
        const r = await this.api.form(tenant, id);
        if (r.ok) return { detail: r.data, detailStatus: 'ready' };
        this.onError(r.error);
        return { detailStatus: 'error' };
      }
      const r = await this.api.entries(tenant, id);
      if (r.ok) return { entries: r.data.items, entriesStatus: 'ready' };
      this.onError(r.error);
      return { entriesStatus: 'error' };
    } catch {
      return kind === 'stats'
        ? { statsStatus: 'error' }
        : kind === 'detail'
          ? { detailStatus: 'error' }
          : { entriesStatus: 'error' };
    }
  }
}
