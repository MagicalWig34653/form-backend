import type { JsonObject } from '../api/admin';

/** Editable state of the `form.mail` section (docs/decisions/0010-mailversand.md). Mirrors the server's rules for fast feedback; the
 * server validates again and is authoritative. */
export interface MailTemplateForm {
  subject: string;
  body: string;
  format: 'text' | 'html';
}
/** One entry of `form.mail.derived` (ADR 0035): a named template value computed from submitted fields. */
export interface DerivedRule {
  name: string;
  op: 'join' | 'firstNonEmpty' | 'date' | 'now';
  /** join / firstNonEmpty: field names, one per line or comma separated. */
  fields: string;
  separator: string;
  /** date: the source field. */
  field: string;
  format: string;
  timeZone: string;
}
export interface MailForm {
  derived: DerivedRule[];
  fromAddress: string;
  fromName: string;
  organisation: MailTemplateForm & {
    enabled: boolean;
    to: string;
    bcc: string;
    replyToField: string;
  };
  confirmation: MailTemplateForm & { enabled: boolean; toField: string };
}

export const emptyDerivedRule = (): DerivedRule => ({
  name: '',
  op: 'join',
  fields: '',
  separator: ' ',
  field: '',
  format: 'dd.MM.yyyy',
  timeZone: 'Europe/Berlin',
});

export const emptyMailForm = (): MailForm => ({
  derived: [],
  fromAddress: '',
  fromName: '',
  organisation: {
    enabled: true,
    to: '',
    bcc: '',
    replyToField: '',
    subject: '',
    body: '',
    format: 'text',
  },
  confirmation: { enabled: false, toField: '', subject: '', body: '', format: 'text' },
});

const obj = (v: unknown): JsonObject =>
  v && typeof v === 'object' && !Array.isArray(v) ? (v as JsonObject) : {};
const str = (v: unknown) => (typeof v === 'string' ? v : '');
const strings = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : [];

/** Same shape as the server's MailAddress: plain ASCII `local@domain.tld`. */
export function isMailAddress(s: string): boolean {
  const v = s.trim();
  if (v.length < 3 || v.length > 254 || !/^[\x21-\x7e]+$/.test(v)) return false;
  const parts = v.split('@');
  if (parts.length !== 2) return false;
  const [local, domain] = parts as [string, string];
  if (
    local.length < 1 ||
    local.length > 64 ||
    local.startsWith('.') ||
    local.endsWith('.') ||
    local.includes('..')
  )
    return false;
  if (!/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local)) return false;
  const labels = domain.split('.');
  return (
    labels.length >= 2 &&
    labels.every(
      (l) =>
        l.length >= 1 &&
        l.length <= 63 &&
        !l.startsWith('-') &&
        !l.endsWith('-') &&
        /^[A-Za-z0-9-]+$/.test(l),
    ) &&
    /^[A-Za-z]{2,}$/.test(labels[labels.length - 1]!)
  );
}

export function parseAddressLines(text: string): string[] {
  return text
    .split(/[\n,;]+/)
    .map((x) => x.trim())
    .filter((x) => x !== '');
}

export function mailToForm(mail: unknown): MailForm {
  const f = emptyMailForm();
  const m = obj(mail);
  if (Object.keys(m).length === 0) return f;
  const from = obj(m.from);
  f.fromAddress = str(from.address);
  f.fromName = str(from.name);
  const o = obj(m.organisation);
  f.organisation = {
    enabled: Object.keys(o).length > 0,
    to: strings(o.to).join('\n'),
    bcc: strings(o.bcc).join('\n'),
    replyToField: str(o.replyToField),
    subject: str(o.subject),
    body: str(o.body),
    format: o.format === 'html' ? 'html' : 'text',
  };
  f.derived = Object.entries(obj(m.derived)).map(([name, raw]) => {
    const d = obj(raw);
    const op = d.op === 'firstNonEmpty' || d.op === 'date' || d.op === 'now' ? d.op : 'join';
    return {
      ...emptyDerivedRule(),
      name,
      op,
      fields: strings(d.fields).join('\n'),
      separator: typeof d.separator === 'string' ? d.separator : ' ',
      field: str(d.field),
      format: str(d.format) || emptyDerivedRule().format,
      timeZone: str(d.timeZone) || emptyDerivedRule().timeZone,
    };
  });
  const c = obj(m.confirmation);
  f.confirmation = {
    enabled: Object.keys(c).length > 0,
    toField: str(c.toField),
    subject: str(c.subject),
    body: str(c.body),
    format: c.format === 'html' ? 'html' : 'text',
  };
  return f;
}

/** `null` when neither mail is switched on (the section is then removed). */
export function formToMail(f: MailForm): JsonObject | null {
  if (!f.organisation.enabled && !f.confirmation.enabled) return null;
  const mail: JsonObject = {
    from: {
      address: f.fromAddress.trim(),
      ...(f.fromName.trim() ? { name: f.fromName.trim() } : {}),
    },
  };
  if (f.organisation.enabled) {
    const o = f.organisation;
    const bcc = parseAddressLines(o.bcc);
    mail.organisation = {
      to: parseAddressLines(o.to),
      ...(bcc.length ? { bcc } : {}),
      ...(o.replyToField ? { replyToField: o.replyToField } : {}),
      subject: o.subject,
      body: o.body,
      format: o.format,
    };
  }
  if (f.confirmation.enabled) {
    const c = f.confirmation;
    mail.confirmation = { toField: c.toField, subject: c.subject, body: c.body, format: c.format };
  }
  if (f.derived.length) {
    mail.derived = Object.fromEntries(
      f.derived.map((d) => {
        const fields = parseAddressLines(d.fields);
        const spec: JsonObject =
          d.op === 'join'
            ? { op: 'join', fields, separator: d.separator }
            : d.op === 'firstNonEmpty'
              ? { op: 'firstNonEmpty', fields }
              : d.op === 'date'
                ? { op: 'date', field: d.field, format: d.format }
                : { op: 'now', format: d.format, timeZone: d.timeZone };
        return [d.name.trim(), spec];
      }),
    );
  }
  return mail;
}

export type MailErrors = Partial<Record<string, string>>;

/** Keys: fromAddress, orgTo, orgBcc, orgSubject, orgBody, confToField, confSubject, confBody. Values are i18n keys. */
export function validateMailForm(f: MailForm, fieldNames: string[]): MailErrors {
  const e: MailErrors = {};
  if (!f.organisation.enabled && !f.confirmation.enabled) return e;
  if (!isMailAddress(f.fromAddress)) e.fromAddress = 'address';
  const text = (t: MailTemplateForm, subject: string, body: string) => {
    if (t.subject.trim() === '' || t.subject.length > 300 || /[\r\n]/.test(t.subject))
      e[subject] = 'subject';
    if (t.body.trim() === '' || new TextEncoder().encode(t.body).length > 100_000) e[body] = 'body';
  };
  if (f.organisation.enabled) {
    const to = parseAddressLines(f.organisation.to),
      bcc = parseAddressLines(f.organisation.bcc);
    if (to.length === 0 || to.length > 20 || !to.every(isMailAddress)) e.orgTo = 'recipients';
    if (bcc.length > 20 || !bcc.every(isMailAddress)) e.orgBcc = 'recipients';
    text(f.organisation, 'orgSubject', 'orgBody');
  }
  const seen = new Set<string>();
  for (const d of f.derived) {
    const name = d.name.trim();
    const inputs = d.op === 'date' ? [d.field] : parseAddressLines(d.fields);
    const bad =
      !/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(name) ||
      fieldNames.includes(name) ||
      seen.has(name) ||
      (d.op !== 'now' &&
        (inputs.length === 0 ||
          inputs.length > 10 ||
          !inputs.every((x) => fieldNames.includes(x)))) ||
      (d.op !== 'join' &&
        d.op !== 'firstNonEmpty' &&
        (d.format.length < 1 || d.format.length > 40));
    seen.add(name);
    if (bad) e.derived = 'derived';
  }
  if (f.derived.length > 20) e.derived = 'derived';
  if (f.confirmation.enabled) {
    if (!fieldNames.includes(f.confirmation.toField)) e.confToField = 'field';
    text(f.confirmation, 'confSubject', 'confBody');
  }
  return e;
}
