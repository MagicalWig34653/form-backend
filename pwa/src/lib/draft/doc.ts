import type { JsonObject } from '../api/admin';
import { sha256Hex } from './jcs';

/** Pure edits of the draft document (form + flow + views, contracts/flow). The server validates everything again; these helpers
 * keep the parts consistent that the UI changes: the views' fields, the views' reference to the form (version + hash) and the
 * mail section. Every function returns a new document. */

export type FieldKind = 'text' | 'email' | 'date' | 'number' | 'boolean' | 'choice';
export const FIELD_KINDS: FieldKind[] = ['text', 'email', 'date', 'number', 'boolean', 'choice'];

export interface FieldInfo {
  id: string;
  name: string;
  label: string;
  kind: string;
  required: boolean;
  options: string[];
}
export interface FieldInput {
  name: string;
  label: string;
  kind: FieldKind;
  required: boolean;
  options?: string[];
}

/** Names double as mail placeholders (`\w+`) and as top-level request names (PHP rewrites "." and " "): keep them plain. */
export const NAME_PATTERN = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
const RESERVED = new Set([
  'csrf_token',
  'cf_turnstile_response',
  'g_recaptcha_response',
  'h_captcha_response',
]);

// Documents are plain JSON; a JSON round trip also copes with Svelte state proxies (structuredClone does not).
const clone = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const obj = (v: unknown): JsonObject =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as JsonObject) : {};

export function formOf(doc: JsonObject): JsonObject {
  return obj(doc.form);
}
export function viewsOf(doc: JsonObject): JsonObject[] {
  return Array.isArray(doc.views) ? (doc.views as JsonObject[]) : [];
}

export function title(doc: JsonObject): string {
  return String(obj(formOf(doc).title).de ?? '');
}

export function fieldList(doc: JsonObject): FieldInfo[] {
  const fields = obj(formOf(doc).fields);
  return Object.entries(fields).map(([id, raw]) => {
    const f = obj(raw);
    const validation = obj(f.validation);
    return {
      id,
      name: String(f.name ?? ''),
      label: String(obj(f.label).de ?? ''),
      kind: String(f.kind ?? 'text'),
      required: f.required === true,
      options: Array.isArray(validation.enum) ? (validation.enum as unknown[]).map(String) : [],
    };
  });
}

export type FieldProblem = 'name' | 'reserved' | 'duplicate' | 'label' | 'options';

export function validateFieldInput(
  doc: JsonObject,
  input: FieldInput,
  ignoreId?: string,
): FieldProblem | null {
  if (!NAME_PATTERN.test(input.name)) return 'name';
  if (RESERVED.has(input.name.toLowerCase())) return 'reserved';
  if (fieldList(doc).some((f) => f.id !== ignoreId && f.name === input.name)) return 'duplicate';
  if (input.label.trim() === '' || input.label.length > 200) return 'label';
  if (input.kind === 'choice') {
    const o = input.options ?? [];
    if (
      o.length < 1 ||
      o.length > 100 ||
      o.some((x) => x.trim() === '' || x.length > 200) ||
      new Set(o).size !== o.length
    )
      return 'options';
  }
  return null;
}

function validationFor(input: FieldInput): JsonObject {
  switch (input.kind) {
    case 'email':
      return { type: 'string', format: 'email' };
    case 'date':
      return { type: 'string', format: 'date' };
    case 'number':
      return { type: 'string', pattern: '^-?[0-9]+([.,][0-9]+)?$' };
    case 'boolean':
      return { type: 'string', enum: ['0', '1', 'true', 'false', 'on', 'off'] };
    case 'choice':
      return { type: 'string', enum: [...(input.options ?? [])] };
    default:
      return { type: 'string' };
  }
}

function fieldObject(input: FieldInput): JsonObject {
  return {
    name: input.name,
    kind: input.kind,
    label: { de: input.label.trim() },
    required: input.required,
    hidden: false,
    locked: false,
    sensitive: input.kind === 'email',
    validation: validationFor(input),
  };
}

/** `^[A-Za-z][A-Za-z0-9._-]{0,127}$`, unique within the form. */
export function newFieldId(doc: JsonObject, name: string): string {
  const taken = new Set(Object.keys(obj(formOf(doc).fields)));
  const base = name;
  let id = base;
  for (let i = 2; taken.has(id); i++) id = `${base}_${i}`;
  return id;
}

/** Every view shows every field: appended to the first section of the first step (the standard document has exactly one). */
export function addField(doc: JsonObject, input: FieldInput): JsonObject {
  const next = clone(doc);
  const form = formOf(next);
  const id = newFieldId(next, input.name);
  form.fields = { ...obj(form.fields), [id]: fieldObject(input) };
  for (const view of viewsOf(next)) {
    const step = obj((view.steps as JsonObject[] | undefined)?.[0]);
    const section = obj((step.sections as JsonObject[] | undefined)?.[0]);
    if (Array.isArray(section.fields))
      (section.fields as JsonObject[]).push({ fieldId: id, readOnly: false, disabled: false });
  }
  return next;
}

export function updateField(doc: JsonObject, id: string, input: FieldInput): JsonObject {
  const next = clone(doc);
  const fields = obj(formOf(next).fields);
  if (!(id in fields)) return next;
  fields[id] = fieldObject(input);
  return next;
}

/** Which mail settings point at this field (they block its removal). */
export function mailReferences(doc: JsonObject, fieldName: string): string[] {
  const mail = obj(formOf(doc).mail);
  const refs: string[] = [];
  if (obj(mail.confirmation).toField === fieldName) refs.push('confirmation.toField');
  if (obj(mail.organisation).replyToField === fieldName) refs.push('organisation.replyToField');
  return refs;
}

export function removeField(doc: JsonObject, id: string): JsonObject {
  const next = clone(doc);
  const form = formOf(next);
  const fields = { ...obj(form.fields) };
  delete fields[id];
  form.fields = fields;
  for (const view of viewsOf(next)) {
    for (const step of (view.steps as JsonObject[]) ?? [])
      for (const section of (step.sections as JsonObject[]) ?? [])
        section.fields = ((section.fields as JsonObject[]) ?? []).filter((f) => f.fieldId !== id);
  }
  return next;
}

export function setTitle(doc: JsonObject, text: string): JsonObject {
  const next = clone(doc);
  formOf(next).title = { ...obj(formOf(next).title), de: text.trim() };
  return next;
}

/** `mail: null` removes the section. */
export function setMail(doc: JsonObject, mail: JsonObject | null): JsonObject {
  const next = clone(doc);
  const form = formOf(next);
  if (mail === null) delete form.mail;
  else form.mail = mail;
  return next;
}

/** The views reference the form by version and content hash; after any change to the form both must be refreshed. */
export async function restamp(doc: JsonObject): Promise<JsonObject> {
  const next = clone(doc);
  const form = formOf(next);
  const hash = await sha256Hex(form);
  for (const view of viewsOf(next))
    view.form = { ...obj(view.form), version: form.version, sha256: hash };
  return next;
}

export function bumpMinor(version: string): string {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(version);
  if (!m) return version;
  return `${m[1]}.${Number(m[2]) + 1}.0`;
}

/** Published versions are immutable: after a change, form and views need a new version number. */
export function bumpVersions(doc: JsonObject): JsonObject {
  const next = clone(doc);
  const form = formOf(next);
  form.version = bumpMinor(String(form.version));
  for (const view of viewsOf(next)) view.version = bumpMinor(String(view.version));
  return next;
}
