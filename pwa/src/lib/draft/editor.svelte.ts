import type { AdminApi, Draft, FormDetail, JsonObject } from '../api/admin';
import type { ApiError } from '../api/client';
import { restamp } from './doc';

/** One form's loaded state plus draft editing: every edit is restamped and saved at once (whole-document PATCH with If-Match). */
export function createEditor(api: AdminApi, tenant: string, formId: string) {
  const s = $state<{
    loading: boolean;
    detail: FormDetail | null;
    draft: Draft | null;
    saving: boolean;
    error: ApiError | null;
  }>({ loading: true, detail: null, draft: null, saving: false, error: null });

  async function load(): Promise<void> {
    // Only the first load hides the page; reloads keep the tabs (and their messages) in place.
    if (!s.detail) s.loading = true;
    s.error = null;
    const d = await api.form(tenant, formId);
    if (!d.ok) {
      s.error = d.error;
      s.loading = false;
      return;
    }
    s.detail = d.data;
    s.draft = null;
    const newest = d.data.draftIds[0];
    if (newest) {
      const dr = await api.draft(tenant, formId, newest);
      if (dr.ok) s.draft = dr.data;
      else s.error = dr.error;
    }
    s.loading = false;
  }

  async function createDraft(): Promise<boolean> {
    s.saving = true;
    s.error = null;
    const r = await api.createDraft(tenant, formId);
    s.saving = false;
    if (!r.ok) {
      s.error = r.error;
      return false;
    }
    s.draft = r.data;
    return true;
  }

  /** Applies `change` to the document, restamps hash references and saves. Resolves to the error, or null on success. */
  async function apply(change: (doc: JsonObject) => JsonObject): Promise<ApiError | null> {
    const current = s.draft;
    if (!current || s.saving) return null;
    s.saving = true;
    s.error = null;
    try {
      const next = await restamp(change(current.document));
      const r = await api.updateDraft(tenant, formId, current.id, next, current.revision);
      if (!r.ok) {
        s.error = r.error;
        return r.error;
      }
      s.draft = r.data;
      return null;
    } finally {
      s.saving = false;
    }
  }

  return {
    get loading() {
      return s.loading;
    },
    get detail() {
      return s.detail;
    },
    get draft() {
      return s.draft;
    },
    get saving() {
      return s.saving;
    },
    get error() {
      return s.error;
    },
    clearError() {
      s.error = null;
    },
    load,
    createDraft,
    apply,
  };
}

export type Editor = ReturnType<typeof createEditor>;
