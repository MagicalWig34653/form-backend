// SPDX-License-Identifier: AGPL-3.0-only
import { t } from '$lib/i18n';
export interface LocalRow {
  id: string;
  receivedAt: string | null;
  fields: unknown;
  unreadable: boolean;
}
export interface Filters {
  query: string;
  from: string;
  until: string;
}

function text(value: unknown): string {
  if (value === null || value === undefined) return '';
  if (typeof value !== 'object') return String(value);
  return Object.entries(value)
    .map(([key, v]) => `${key} ${text(v)}`)
    .join(' ');
}
export function inPeriod(date: string | null, filters: Filters): boolean {
  if (!filters.from && !filters.until) return true;
  if (!date) return false;
  const day = date.slice(0, 10); // UTC date, as labelled in the UI
  return (!filters.from || day >= filters.from) && (!filters.until || day <= filters.until);
}
/** Unreadable candidates stay visible as unknown matches, never as proven person hits. */
export function matches(row: LocalRow, filters: Filters): boolean {
  return (
    inPeriod(row.receivedAt, filters) &&
    (row.unreadable ||
      text(row.fields)
        .normalize('NFKC')
        .toLocaleLowerCase('de')
        .includes(filters.query.trim().normalize('NFKC').toLocaleLowerCase('de')))
  );
}
export function csvCell(value: string): string {
  // Guard headers too, including formulas hidden after whitespace/control characters.
  // eslint-disable-next-line no-control-regex -- CSV formulas may hide behind ASCII controls.
  const dangerous = /^[\s\u0000-\u001f]*[=+\-@]/u.test(value);
  const safe = dangerous || /^[\t\r\n]/u.test(value) ? `'${value}` : value;
  return `"${safe.replaceAll('"', '""')}"`;
}
export function serialize(rows: LocalRow[], format: 'csv' | 'json'): string {
  if (format === 'json') return JSON.stringify({ entries: rows }, null, 2);
  const fields = (row: LocalRow): Record<string, unknown> =>
    row.fields && typeof row.fields === 'object'
      ? (row.fields as Record<string, unknown>)
      : { value: row.fields };
  const names = [...new Set(rows.flatMap((row) => Object.keys(fields(row))))].sort();
  const value = (v: unknown): string =>
    v === null || v === undefined ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v);
  const lines = [
    [
      t.localExport.columnId,
      t.localExport.columnDate,
      t.localExport.columnUnreadable,
      ...names.map((name) => `${t.localExport.columnField}: ${name}`),
    ],
    ...rows.map((r) => [
      r.id,
      r.receivedAt ?? '',
      String(r.unreadable),
      ...names.map((name) => value(fields(r)[name])),
    ]),
  ];
  return '\uFEFF' + lines.map((line) => line.map(csvCell).join(',')).join('\r\n') + '\r\n';
}
