// SPDX-License-Identifier: AGPL-3.0-only
import { adminApi, http } from '$lib/api';
import { keyring } from '$lib/crypto/keyring.svelte';
import { openPackage } from '$lib/crypto/packageV2';
import type { ApiResult } from '$lib/api/client';
import type { Filters, LocalRow } from './content';
import { inPeriod } from './content';

const base = (tenant: string, form: string) =>
  `/tenants/${encodeURIComponent(tenant)}/forms/${encodeURIComponent(form)}`;
export interface Access {
  canExport: boolean;
  canDelete: boolean;
}
export class RequestFailure extends Error {
  constructor(readonly error: import('$lib/api/client').ApiError) {
    super(error.kind);
  }
}
export function unwrap<T>(result: ApiResult<T>): T {
  if (!result.ok) throw new RequestFailure(result.error);
  return result.data;
}
export async function access(tenant: string, form: string): Promise<Access> {
  return unwrap(await http.request<Access>('GET', `${base(tenant, form)}/entries/local-access`));
}
export async function audit(tenant: string, form: string): Promise<void> {
  unwrap(await http.request<void>('POST', `${base(tenant, form)}/export/audit`, { body: {} }));
}
/** Sequential pages bound requests; cancellation prevents late plaintext publication. No plaintext cache. */
export async function scan(
  tenant: string,
  form: string,
  filters: Filters,
  check: () => void,
  progress: (n: number) => void,
): Promise<LocalRow[]> {
  const operation = keyring.operation();
  const rows: LocalRow[] = [];
  const off = keyring.onLock(() => {
    rows.length = 0;
  });
  let cursor: string | undefined;
  const cursors = new Set<string>();
  const ids = new Set<string>();
  const current = () => {
    operation.check();
    check();
  };
  try {
    await access(tenant, form);
    current();
    do {
      const page = unwrap(await adminApi.entries(tenant, form, cursor));
      current();
      for (const entry of page.items) {
        if (ids.has(entry.id)) continue;
        ids.add(entry.id);
        if (!inPeriod(entry.receivedAt, filters)) continue;
        // Transport/authorization failures abort the scan; only content/key failures become markers.
        const sealed = unwrap(await adminApi.ciphertext(tenant, form, entry.id));
        current();
        let fields: unknown = {},
          unreadable = true;
        const key = keyring.dataKey(sealed.keyId, false);
        if (key) {
          let bytes: Uint8Array | undefined;
          try {
            bytes = await openPackage(sealed.package, operation.copy(key));
            current();
            const doc = JSON.parse(new TextDecoder().decode(bytes));
            if (!doc || typeof doc !== 'object' || !('fields' in doc)) throw new Error();
            fields = doc.fields;
            unreadable = false;
          } catch {
            current();
          } finally {
            bytes?.fill(0);
          }
        }
        current();
        rows.push({ id: entry.id, receivedAt: entry.receivedAt, fields, unreadable });
        progress(rows.length);
      }
      cursor = page.nextCursor ?? undefined;
      if (cursor && cursors.has(cursor)) throw new Error();
      if (cursor) cursors.add(cursor);
    } while (cursor);
    await access(tenant, form);
    current();
    return rows;
  } finally {
    off();
    operation.dispose();
  }
}
