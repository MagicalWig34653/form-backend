import { describe, expect, it } from 'vitest';
import { csvCell, matches, serialize, type LocalRow } from './content';
const row: LocalRow = {
  id: 'a',
  receivedAt: '2026-11-03T10:00:00Z',
  fields: { name: 'Müller', nested: { email: 'person@example.invalid' }, formula: '=1+1' },
  unreadable: false,
};
describe('local search and export', () => {
  it('searches nested fields, keys and normalized case locally within inclusive UTC dates', () => {
    for (const query of ['MÜLLER', 'EMAIL', 'example.invalid'])
      expect(matches(row, { query, from: '2026-11-03', until: '2026-11-03' })).toBe(true);
    expect(matches(row, { query: 'other', from: '', until: '' })).toBe(false);
    expect(matches(row, { query: '', from: '2026-11-04', until: '' })).toBe(false);
    expect(
      matches({ ...row, receivedAt: null }, { query: '', from: '2026-11-01', until: '' }),
    ).toBe(false);
  });
  it('keeps undecipherable candidates explicit even with a person filter', () => {
    const unknown = { ...row, fields: {}, unreadable: true };
    expect(matches(unknown, { query: 'unknown person', from: '', until: '' })).toBe(true);
    expect(JSON.parse(serialize([row, unknown], 'json')).entries).toEqual([row, unknown]);
    expect(serialize([row, unknown], 'csv')).toContain('"true"');
  });
  it('neutralizes formulas including whitespace and quotes every cell', () => {
    for (const v of ['=1+1', '+2', '-3', '@SUM(A1)', ' \t=1', '\n=2', '\ttext', '\rtext'])
      expect(csvCell(v)).toBe(`"'${v}"`);
    expect(csvCell('a,"b"\n')).toBe('"a,""b""\n"');
    const csv = serialize([row], 'csv');
    expect(csv).toContain('"\'=1+1"');
    expect(csv).toContain('Feld: nested');
    expect(csv).toContain('person@example.invalid');
    expect(csv.endsWith('\r\n')).toBe(true);
  });
});
