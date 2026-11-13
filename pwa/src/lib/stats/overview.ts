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

/** A form of the list, optionally with its customer (overall dashboard). */
export type ScopedForm = FormListItem & { tenant?: string };

export interface AttentionItem {
  id: string;
  /** Customer of the form when it differs from the page's customer. */
  tenant?: string;
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
  forms: ScopedForm[],
  snapshots: Map<string, FormSnapshot>,
  locked: boolean,
): AttentionItem[] {
  const out: AttentionItem[] = [];
  if (locked) out.push({ id: 'locked', tone: 'warn', kind: 'locked' });
  for (const f of forms) {
    const snap = snapshots.get(f.id);
    const base = { formId: f.id, formName: f.name, ...(f.tenant ? { tenant: f.tenant } : {}) };
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
  /** How many forms satisfy a per-form step; only set when the customer has several forms. */
  count?: { done: number; total: number };
}

/**
 * Customer-wide setup progress. Per-form steps (mail, published, active) are done only when every
 * form they concern satisfies them, so that a step is never ticked while the next-step hint still
 * points at a form lacking it. "Eingeschaltet" concerns published forms only (a draft cannot be
 * switched on); "traffic" is done once any form had a visit or submission.
 */
export function setupSteps(
  forms: FormListItem[],
  snapshots: Map<string, FormSnapshot>,
): SetupStep[] {
  const snaps = forms.map((f) => snapshots.get(f.id));
  const trafficKnown = snaps.every((s) => (s?.statsStatus ?? 'loading') !== 'loading');
  const trafficDone = snaps.some((s) => s?.stats && (s.stats.visits > 0 || s.stats.submits > 0));
  const loaded = (f: FormListItem): boolean =>
    (snapshots.get(f.id)?.detailStatus ?? 'loading') !== 'loading';
  const hasMail = (f: FormListItem): boolean => !!snapshots.get(f.id)?.detail?.mailConnectionId;
  const idOf = (id: string | undefined) => (id ? { formId: id } : {});
  const counted = (done: number, total: number) => (total > 1 ? { count: { done, total } } : {});

  const withMail = forms.filter(hasMail).length;
  const lackingMail = forms.find((f) => loaded(f) && !hasMail(f));
  const mailKnown = forms.every(loaded);
  const published = forms.filter((f) => f.currentReleaseId);
  const unpublished = forms.find((f) => !f.currentReleaseId);
  const switchedOn = published.filter((f) => f.active);
  const off = published.find((f) => !f.active);

  return [
    { id: 'form', done: forms.length > 0, ...idOf(forms[0]?.id) },
    {
      id: 'mail',
      done: lackingMail ? false : mailKnown ? forms.length > 0 : null,
      ...idOf(lackingMail?.id),
      ...counted(withMail, forms.length),
    },
    {
      id: 'published',
      done: forms.length > 0 && !unpublished,
      ...idOf(unpublished?.id),
      ...counted(published.length, forms.length),
    },
    {
      id: 'active',
      done: published.length > 0 && !off,
      ...idOf(off?.id),
      ...counted(switchedOn.length, published.length),
    },
    {
      id: 'traffic',
      done: trafficDone ? true : trafficKnown ? false : null,
      ...idOf(forms[0]?.id),
    },
  ];
}
