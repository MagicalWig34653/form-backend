import type { EntryItem, FormDetail, FormListItem, Statistics } from '$lib/api/admin';
import { dailySeries, sumSeries, type Series } from './series';

export type PartStatus = 'loading' | 'ready' | 'error';

/** Everything the overview knows about one form; each part loads and fails on its own. */
export interface FormSnapshot {
  stats: Statistics | null;
  statsStatus: PartStatus;
  detail: FormDetail | null;
  detailStatus: PartStatus;
  entries: EntryItem[] | null;
  entriesStatus: PartStatus;
}

export const emptySnapshot = (): FormSnapshot => ({
  stats: null,
  statsStatus: 'loading',
  detail: null,
  detailStatus: 'loading',
  entries: null,
  entriesStatus: 'loading',
});

/** Combined state of one kind of data over all forms: ready as soon as one form delivers. */
export function combinedStatus(statuses: PartStatus[]): {
  status: PartStatus;
  ready: number;
  total: number;
} {
  const ready = statuses.filter((s) => s === 'ready').length;
  const loading = statuses.some((s) => s === 'loading');
  const status: PartStatus = ready > 0 ? 'ready' : loading ? 'loading' : 'error';
  return { status, ready, total: statuses.length };
}

/** Summed series over the forms whose statistics have arrived (null when none). */
export function aggregate(
  snapshots: FormSnapshot[],
  metric: 'visits' | 'submits',
  count = 14,
): Series | null {
  const list = snapshots.flatMap((s) => (s.stats ? [dailySeries(s.stats, metric, count)] : []));
  return list.length === 0 ? null : sumSeries(list, count);
}

export interface AttentionItem {
  id: string;
  tone: 'warn' | 'info';
  kind: 'locked' | 'noMail' | 'unpublished' | 'inactive' | 'quiet';
  formId?: string;
  formName?: string;
}

/**
 * Hints derived from loaded metadata only. `quiet` = published and active, statistics known,
 * and not a single visit or submission in the whole period.
 */
export function deriveAttention(
  forms: FormListItem[],
  snapshots: Map<string, FormSnapshot>,
  locked: boolean,
): AttentionItem[] {
  const out: AttentionItem[] = [];
  if (locked) out.push({ id: 'locked', tone: 'warn', kind: 'locked' });
  for (const f of forms) {
    const snap = snapshots.get(f.id);
    const base = { formId: f.id, formName: f.name };
    if (!f.currentReleaseId)
      out.push({ id: `unpublished-${f.id}`, tone: 'info', kind: 'unpublished', ...base });
    else if (!f.active)
      out.push({ id: `inactive-${f.id}`, tone: 'warn', kind: 'inactive', ...base });
    if (snap?.detailStatus === 'ready' && snap.detail && !snap.detail.mailConnectionId)
      out.push({ id: `nomail-${f.id}`, tone: 'warn', kind: 'noMail', ...base });
    if (f.currentReleaseId && f.active && snap?.stats) {
      if (snap.stats.visits === 0 && snap.stats.submits === 0)
        out.push({ id: `quiet-${f.id}`, tone: 'info', kind: 'quiet', ...base });
    }
  }
  return out;
}

export type SetupStepId = 'form' | 'mail' | 'published' | 'active' | 'traffic';
export interface SetupStep {
  id: SetupStepId;
  /** null while it cannot be known yet. */
  done: boolean | null;
  /** Form that would need work for this step (first one lacking it). */
  formId?: string;
}

/** Customer-wide setup progress: a step is done once any loaded form satisfies it. */
export function setupSteps(
  forms: FormListItem[],
  snapshots: Map<string, FormSnapshot>,
): SetupStep[] {
  const snaps = forms.map((f) => snapshots.get(f.id));
  const mailKnown = snaps.every((s) => (s?.detailStatus ?? 'loading') !== 'loading');
  const trafficKnown = snaps.every((s) => (s?.statsStatus ?? 'loading') !== 'loading');
  const mailDone = snaps.some((s) => s?.detail?.mailConnectionId);
  const trafficDone = snaps.some((s) => s?.stats && (s.stats.visits > 0 || s.stats.submits > 0));
  const firstWithout = (pred: (f: FormListItem) => boolean): string | undefined =>
    forms.find(pred)?.id;
  const idOf = (id: string | undefined) => (id ? { formId: id } : {});
  return [
    { id: 'form', done: forms.length > 0, ...idOf(forms[0]?.id) },
    {
      id: 'mail',
      done: mailDone ? true : mailKnown ? false : null,
      ...idOf(firstWithout((f) => !snapshots.get(f.id)?.detail?.mailConnectionId)),
    },
    {
      id: 'published',
      done: forms.some((f) => f.currentReleaseId),
      ...idOf(firstWithout((f) => !f.currentReleaseId)),
    },
    {
      id: 'active',
      done: forms.some((f) => f.currentReleaseId && f.active),
      ...idOf(firstWithout((f) => !f.active)),
    },
    {
      id: 'traffic',
      done: trafficDone ? true : trafficKnown ? false : null,
      ...idOf(forms[0]?.id),
    },
  ];
}
