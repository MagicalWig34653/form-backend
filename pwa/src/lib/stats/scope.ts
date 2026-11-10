import type { FormListState } from '$lib/area';
import type { FormSnapshot, ScopedForm } from './overview';

/**
 * Flat list of all forms over several customers for the overall dashboard. Each form carries its
 * customer; with several customers the name is prefixed ("Kunde · Formular"). Customers whose list
 * is missing or failed are reported separately instead of contributing zeros.
 */
export function scopeForms(
  tenants: readonly { id: string; name: string }[],
  lists: ReadonlyMap<string, FormListState>,
): { forms: ScopedForm[]; failed: { id: string; name: string }[]; more: boolean } {
  const forms: ScopedForm[] = [];
  const failed: { id: string; name: string }[] = [];
  let more = false;
  for (const c of tenants) {
    const state = lists.get(c.id);
    if (!state || state.status === 'error') {
      failed.push(c);
      continue;
    }
    if (state.more) more = true;
    for (const f of state.items)
      forms.push({
        ...f,
        tenant: c.id,
        name: tenants.length > 1 ? `${c.name} · ${f.name}` : f.name,
      });
  }
  return { forms, failed, more };
}

/** Forms of which any part (statistics, detail, entries) could not be loaded. */
export function failedForms(
  forms: readonly ScopedForm[],
  snapshots: ReadonlyMap<string, FormSnapshot>,
): ScopedForm[] {
  return forms.filter((f) => {
    const s = snapshots.get(f.id);
    return (
      s && (s.statsStatus === 'error' || s.detailStatus === 'error' || s.entriesStatus === 'error')
    );
  });
}
