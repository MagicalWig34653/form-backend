// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from 'vitest';
import { normalizePayload, readableLabel } from './payload';

const rows = (p: unknown) => normalizePayload(p).fields.map((f) => [f.label, f.value]);

describe('new format {fields, files}', () => {
  it('keeps the raw key path as label and flattens nested values', () => {
    const p = { fields: { message: 'Hallo', address: { street: 'Weg 1' } }, files: {} };
    expect(rows(p)).toEqual([
      ['message', 'Hallo'],
      ['address[street]', 'Weg 1'],
    ]);
  });
  it('hands the files branch through for attachment ordinals', () => {
    const f = { name: 'a.pdf', size: 3, sha256: 'ab' };
    expect(normalizePayload({ fields: { x: '1' }, files: { doc: f } }).files).toEqual({ doc: f });
  });
  it('accepts a missing files branch', () => {
    expect(normalizePayload({ fields: { x: '1' } }).files).toEqual({});
  });
});

describe('flat legacy format (field name -> value)', () => {
  it('shows every field with a readable label and its value', () => {
    const p = { name: 'Jörg', email: 'j@example.invalid', nachricht: 'Grüße', leer: '' };
    expect(rows(p)).toEqual([
      ['Name', 'Jörg'],
      ['Email', 'j@example.invalid'],
      ['Nachricht', 'Grüße'],
      ['Leer', ''],
    ]);
  });
  it('keeps unknown meta keys like any other field (marker, form)', () => {
    expect(rows({ form: 'x', marker: 'KLARTEXT-MARKER-1' })).toEqual([
      ['Form', 'x'],
      ['Marker', 'KLARTEXT-MARKER-1'],
    ]);
  });
  it('joins scalar arrays (checkbox groups) and flattens nested objects', () => {
    expect(rows({ wahl: ['a', 'b'], adresse: { plz: 12345, ort: 'X' } })).toEqual([
      ['Wahl', 'a, b'],
      ['Adresse / Plz', '12345'],
      ['Adresse / Ort', 'X'],
    ]);
  });
  it('numbers arrays of objects', () => {
    expect(rows({ pos: [{ n: 'a' }, { n: 'b' }] })).toEqual([
      ['Pos 1 / N', 'a'],
      ['Pos 2 / N', 'b'],
    ]);
  });
  it('treats a legacy form with a field named "fields" holding a plain value as legacy', () => {
    expect(rows({ fields: 'text', files: 'x' })).toEqual([
      ['Fields', 'text'],
      ['Files', 'x'],
    ]);
  });
  it('shows no attachments for a legacy payload', () => {
    expect(normalizePayload({ name: 'x' }).files).toEqual({});
  });
  it('renders scalars of other types as text', () => {
    expect(rows({ a: 1, b: true, c: null })).toEqual([
      ['A', '1'],
      ['B', 'true'],
      ['C', ''],
    ]);
  });
});

describe('empty and invalid input', () => {
  it.each([null, undefined, 'text', 42, true, []])('yields no fields for %j', (p) => {
    expect(normalizePayload(p)).toEqual({ fields: [], files: {} });
  });
  it('yields no fields for an empty object', () => {
    expect(normalizePayload({})).toEqual({ fields: [], files: {} });
  });
});

describe('values stay text', () => {
  it('returns markup unchanged as a string (rendering escapes it)', () => {
    const html = '<img src=x onerror=alert(1)><script>1</script>';
    const out = normalizePayload({ nachricht: html, '<b>x</b>': 'y' });
    expect(out.fields[0]?.value).toBe(html);
    expect(out.fields[1]?.label).toBe('<b>x</b>');
  });
});

describe('readableLabel', () => {
  it.each([
    ['name', 'Name'],
    ['vor_name', 'Vor name'],
    ['telefonNummer', 'Telefon nummer'],
    ['e-mail', 'E mail'],
    ['', ''],
  ])('%s -> %s', (raw, label) => {
    expect(readableLabel(raw)).toBe(label);
  });
});
