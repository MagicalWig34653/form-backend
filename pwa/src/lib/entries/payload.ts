// SPDX-License-Identifier: AGPL-3.0-only
// Turns a decrypted submission document into rows for the detail view. Two shapes exist (docs/handoffs/Alt-Payload-Format.md):
//  - new:    { fields: { name: value, ... }, files: { ... } }
//  - legacy: the flat POST object of the old system { fieldName: value, ... }  (no files branch; attachments are separate packages)
// Everything stays plain text: values are never interpreted as markup; the view renders them as text nodes.

export interface PayloadField {
  label: string;
  value: string;
}

export interface NormalizedPayload {
  fields: PayloadField[];
  /** The raw `files` branch (new format only) for attachment ordinals; `{}` otherwise. */
  files: unknown;
}

const isObject = (v: unknown): v is Record<string, unknown> =>
  v !== null && typeof v === 'object' && !Array.isArray(v);

/** The new format: a `fields` object next to an optional `files` object and nothing else. */
function isNewFormat(doc: Record<string, unknown>): boolean {
  const keys = Object.keys(doc);
  return (
    isObject(doc.fields) &&
    keys.every((k) => k === 'fields' || k === 'files') &&
    (doc.files === undefined || isObject(doc.files))
  );
}

/** "telefonNummer" / "vor_name" -> "Telefon nummer" / "Vor name": the old field name made readable (no label exists in the payload). */
export function readableLabel(raw: string): string {
  const spaced = raw
    .replace(/[_\-.]+/g, ' ')
    .replace(
      /([\p{Ll}\d])(\p{Lu})(?=\p{Ll})/gu,
      (_m, a: string, b: string) => `${a} ${b.toLowerCase()}`,
    )
    .trim();
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

const text = (v: unknown): string => (v === null || v === undefined ? '' : String(v));
const isScalar = (v: unknown): boolean => v === null || typeof v !== 'object';

function flattenNew(value: unknown, prefix: string): PayloadField[] {
  if (isScalar(value)) return [{ label: prefix, value: text(value) }];
  return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) =>
    flattenNew(v, prefix ? `${prefix}[${k}]` : k),
  );
}

function flattenLegacy(value: unknown, path: string[]): PayloadField[] {
  const label = path.map(readableLabel).join(' / ');
  if (isScalar(value)) return [{ label, value: text(value) }];
  if (Array.isArray(value)) {
    if (value.every(isScalar)) return [{ label, value: value.map(text).join(', ') }];
    const head = path.slice(0, -1);
    const last = path[path.length - 1] ?? '';
    return value.flatMap((v, i) =>
      isScalar(v)
        ? [{ label: `${label} ${i + 1}`, value: text(v) }]
        : flattenLegacy(v, [...head, `${last} ${i + 1}`]),
    );
  }
  return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) =>
    flattenLegacy(v, [...path, k]),
  );
}

export function normalizePayload(doc: unknown): NormalizedPayload {
  if (!isObject(doc)) return { fields: [], files: {} };
  if (isNewFormat(doc)) return { fields: flattenNew(doc.fields, ''), files: doc.files ?? {} };
  return {
    fields: Object.entries(doc).flatMap(([k, v]) => flattenLegacy(v, [k])),
    files: {},
  };
}
