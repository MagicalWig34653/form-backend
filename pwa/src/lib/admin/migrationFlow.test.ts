import { describe, expect, it } from 'vitest';
import {
  canAdvance,
  describeJobError,
  landingStep,
  countRows,
  isSha256,
  mappingIssues,
  reachedStep,
  reportRows,
} from './migrationFlow';

describe('reachedStep', () => {
  it('folgt der Datenlage', () => {
    expect(reachedStep([], false)).toBe(0);
    expect(reachedStep([], true)).toBe(1);
    expect(reachedStep([{ state: 'running', dryRun: true }], false)).toBe(2);
    expect(reachedStep([{ state: 'review', dryRun: true }], false)).toBe(2);
    expect(reachedStep([{ state: 'review', dryRun: false }], false)).toBe(4);
    expect(landingStep([{ state: 'review', dryRun: false }], false)).toBe(3);
    expect(landingStep([{ state: 'running', dryRun: true }], false)).toBe(2);
    expect(reachedStep([{ state: 'failed', dryRun: false }], false)).toBe(2);
    expect(reachedStep([{ state: 'closed', dryRun: false }], false)).toBe(4);
  });
});
describe('canAdvance', () => {
  it('lässt nur erreichte Schritte zu und endet beim letzten', () => {
    expect(canAdvance(0, 0)).toBe(false);
    expect(canAdvance(0, 1)).toBe(true);
    expect(canAdvance(3, 4)).toBe(true);
    expect(canAdvance(4, 4)).toBe(false);
  });
});
describe('mappingIssues', () => {
  const ok = {
    customer: '11111111-1111-4111-8111-111111111111',
    name: 'Kunde',
    forms: '22222222-2222-4222-8222-222222222222\n33333333-3333-4333-8333-333333333333',
    namespace: 'alt',
    snapshot: 'a'.repeat(64),
    expectedSchema: 'b'.repeat(64),
  };
  it('meldet nichts bei vollständigen Angaben', () => {
    expect(mappingIssues(ok)).toEqual([]);
  });
  it('benennt jede fehlende oder fehlerhafte Angabe', () => {
    expect(
      mappingIssues({
        customer: 'x',
        name: ' ',
        forms: 'nope',
        namespace: '',
        snapshot: 'abc',
        expectedSchema: '',
      }),
    ).toEqual(['customer', 'name', 'forms', 'namespace', 'snapshot', 'schema']);
    expect(mappingIssues({ ...ok, forms: '' })).toEqual(['forms']);
  });
});
describe('Berichtszeilen', () => {
  it('flacht Berichte ab und kappt tiefe Strukturen', () => {
    expect(reportRows({ processed: 42, a: { b: 1, c: { d: 2, e: { f: 3 } } } })).toEqual([
      { key: 'processed', value: '42' },
      { key: 'a.b', value: '1' },
      { key: 'a.c.d', value: '2' },
      { key: 'a.c.e', value: '{"f":3}' },
    ]);
    expect(reportRows(null)).toEqual([]);
  });
  it('sortiert Zähler', () => {
    expect(countRows({ b: 2, a: 1 })).toEqual([
      { key: 'a', value: '1' },
      { key: 'b', value: '2' },
    ]);
  });
  it('prüft SHA-256', () => {
    expect(isSha256('a'.repeat(64))).toBe(true);
    expect(isSha256('A'.repeat(64))).toBe(false);
  });
});

describe('describeJobError', () => {
  const texts = {
    reasons: {
      invalidTimestamp: 'Kein gültiger Zeitstempel',
      unknownKeyGeneration: 'Schlüssel fehlt',
    },
    codes: { conflict: 'Ziel enthält schon Daten', migration_failed: 'Unbekannt' },
    column: 'Spalte',
  };
  it('übersetzt feste Codes', () => {
    expect(describeJobError('conflict', texts)).toBe('Ziel enthält schon Daten');
  });
  it('übersetzt Grund@Spalte und nennt die Spalte, nie einen Wert', () => {
    expect(describeJobError('invalidTimestamp@time', texts)).toBe(
      'Kein gültiger Zeitstempel (Spalte time)',
    );
    expect(describeJobError('unknownKeyGeneration@kid', texts)).toContain('Spalte kid');
  });
  it('zeigt unbekannte Codes unverändert', () => {
    expect(describeJobError('etwas_neues', texts)).toBe('etwas_neues');
    expect(describeJobError('unbekannt@x', texts)).toBe('unbekannt@x');
  });
});
