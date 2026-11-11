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
  assignConnections,
  assignForms,
  assignKeys,
  buildPlan,
  generationNumbers,
  keyWarnings,
  sourceConnections,
  sourceForms,
  suggestNamespace,
  summarizeReport,
  type SourceKey,
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
const A = '11111111-1111-4111-8111-111111111111';
const B = '44444444-4444-4444-8444-444444444444';
const F1 = '22222222-2222-4222-8222-222222222222';
const F2 = '33333333-3333-4333-8333-333333333333';
const C1 = '55555555-5555-4555-8555-555555555555';
const key = (kid: string, status: string, createdAt: number, publicKeyValid = true): SourceKey => ({
  kid,
  status,
  createdAt,
  publicKeyValid,
});
const use = (kid: string, submissions: number, formIds: string[], inKeyStore = true) => ({
  kid,
  submissions,
  inKeyStore,
  formIds,
  formIdsComplete: true,
});
const one = [{ id: A, name: 'Kunde A' }];
const two = [...one, { id: B, name: 'Kunde B' }];

describe('Plan aus der Quellprüfung', () => {
  const keys = [
    key('aaaaaaaaaaaaaaaa', 'aktiv', 300),
    key('bbbbbbbbbbbbbbbb', 'auslaufend', 100),
    key('cccccccccccccccc', 'auslaufend', 100),
  ];
  const plan = (extra = '{}', customers = one) =>
    buildPlan({
      namespace: 'legacy-alt',
      snapshot: 'a'.repeat(64),
      customers,
      formCustomers: assignForms([F1, F2], customers, {}),
      connectionCustomers: assignConnections(
        [{ id: C1, kind: 'smtp', name: null }],
        [],
        {},
        customers,
        {},
      ),
      keys,
      keyCustomers: assignKeys(keys, [], {}, customers, {}),
      extra,
    });
  const issues = (
    p: ReturnType<typeof plan>,
    extra: Partial<Parameters<typeof mappingIssues>[0]> = {},
  ) =>
    mappingIssues({
      ...p,
      formIds: [F1, F2],
      connectionIds: [C1],
      keys,
      expectedSchema: 'b'.repeat(64),
      sourceChanged: false,
      ...extra,
    });

  it('ein Kunde: Formulare, Verbindungen und Schlüssel automatisch, Nummern lückenlos', () => {
    const { plan: p, extraValid } = plan();
    expect(extraValid).toBe(true);
    expect(p.formCustomers).toEqual({ [F1]: A, [F2]: A });
    expect(p.connectionCustomers).toEqual({ [C1]: [A] });
    expect(p.keyCustomers).toEqual({
      aaaaaaaaaaaaaaaa: A,
      bbbbbbbbbbbbbbbb: A,
      cccccccccccccccc: A,
    });
    // Auslaufend zuerst, älteste zuerst, Gleichstand nach kid; aktiv erhält die höchste Nummer.
    expect(p.keyGenerationNumbers).toEqual({
      bbbbbbbbbbbbbbbb: 1,
      cccccccccccccccc: 2,
      aaaaaaaaaaaaaaaa: 3,
    });
    expect(issues({ plan: p, extraValid })).toEqual([]);
  });

  it('aktiv bleibt höchste Nummer, auch wenn es älter ist', () => {
    const numbers = generationNumbers(
      [key('aaaaaaaaaaaaaaaa', 'aktiv', 50), key('bbbbbbbbbbbbbbbb', 'auslaufend', 900)],
      { aaaaaaaaaaaaaaaa: A, bbbbbbbbbbbbbbbb: A },
    );
    expect(numbers).toEqual({ bbbbbbbbbbbbbbbb: 1, aaaaaaaaaaaaaaaa: 2 });
  });

  it('nicht übernehmbare Schlüssel werden nicht zugeordnet und nicht nummeriert', () => {
    const list = [
      key('aaaaaaaaaaaaaaaa', 'aktiv', 1),
      key('dddddddddddddddd', 'andere', 2),
      key('eeeeeeeeeeeeeeee', 'auslaufend', 3, false),
    ];
    const assigned = assignKeys(list, [], {}, one, {});
    expect(assigned).toEqual({ aaaaaaaaaaaaaaaa: A });
    expect(generationNumbers(list, { ...assigned, dddddddddddddddd: A })).toEqual({
      aaaaaaaaaaaaaaaa: 1,
    });
    expect(
      keyWarnings(list, [], { keyCustomers: assigned, formCustomers: {} }).skipped,
    ).toHaveLength(2);
  });

  it('mehrere Kunden: Vorbelegung aus den Formularen der Einsendungen, sonst offen', () => {
    const forms = { [F1]: A, [F2]: B };
    const usage = [use('aaaaaaaaaaaaaaaa', 3, [F1]), use('bbbbbbbbbbbbbbbb', 1, [F1, F2])];
    const assigned = assignKeys(keys, usage, forms, two, {});
    expect(assigned).toEqual({ aaaaaaaaaaaaaaaa: A });
    // Unvollständige Formularliste: keine Ableitung.
    expect(assignKeys(keys, [{ ...usage[0]!, formIdsComplete: false }], forms, two, {})).toEqual(
      {},
    );
    // Nutzerwahl gewinnt, unbekannte Kunden werden ignoriert.
    expect(
      assignKeys(keys, usage, forms, two, {
        bbbbbbbbbbbbbbbb: B,
        cccccccccccccccc: 'unbekannt',
      }),
    ).toEqual({ aaaaaaaaaaaaaaaa: A, bbbbbbbbbbbbbbbb: B });
    const p = plan('{}', two);
    expect(issues(p)).toContain('keys');
  });

  it('Formulare und Verbindungen bei mehreren Kunden', () => {
    expect(assignForms([F1, F2], two, { [F2]: B })).toEqual({ [F1]: A, [F2]: B });
    const conns = [
      { id: C1, kind: 'smtp', name: 'Versand' },
      { id: F2, kind: 'mail-proxy', name: null },
    ];
    const forms = [{ id: F1, name: 'Kontakt', connectionIds: [C1] }];
    // C1 vom Formular des Kunden A referenziert, die zweite Verbindung von keinem: offen.
    expect(assignConnections(conns, forms, { [F1]: A }, two, {})).toEqual({ [C1]: [A] });
    expect(assignConnections(conns, forms, { [F1]: A }, two, { [F2]: B })).toEqual({
      [C1]: [A],
      [F2]: [B],
    });
  });

  it('höchstens eine aktive Generation je Kunde', () => {
    const list = [key('aaaaaaaaaaaaaaaa', 'aktiv', 1), key('ffffffffffffffff', 'aktiv', 2)];
    const p = buildPlan({
      namespace: 'n',
      snapshot: 'a'.repeat(64),
      customers: one,
      formCustomers: { [F1]: A },
      connectionCustomers: {},
      keys: list,
      keyCustomers: assignKeys(list, [], {}, one, {}),
      extra: '',
    });
    expect(
      mappingIssues({
        ...p,
        formIds: [F1],
        connectionIds: [],
        keys: list,
        expectedSchema: 'b'.repeat(64),
        sourceChanged: false,
      }),
    ).toEqual(['activeKeys']);
  });

  it('manuelles JSON wird je Eintrag zusammengeführt, Nutzerwerte gewinnen', () => {
    const { plan: p } = plan(
      JSON.stringify({
        keyCustomers: { cccccccccccccccc: B },
        keyGenerationNumbers: { aaaaaaaaaaaaaaaa: 7 },
        customers: { [B]: 'Kunde B' },
        statisticsReview: 'bericht-1',
      }),
    );
    expect(p.keyCustomers.cccccccccccccccc).toBe(B);
    expect(p.keyCustomers.bbbbbbbbbbbbbbbb).toBe(A);
    // Nummern folgen der zusammengeführten Zuordnung, explizite Nummern gewinnen.
    expect(p.keyGenerationNumbers).toEqual({
      bbbbbbbbbbbbbbbb: 1,
      aaaaaaaaaaaaaaaa: 7,
      cccccccccccccccc: 1,
    });
    expect(p.customers).toEqual({ [A]: 'Kunde A', [B]: 'Kunde B' });
    expect(p.statisticsReview).toBe('bericht-1');
    expect(p.formCustomers).toEqual({ [F1]: A, [F2]: A });
  });

  it('benennt fehlende Angaben und ungültiges JSON', () => {
    const broken = plan('{kein json');
    expect(broken.extraValid).toBe(false);
    expect(issues(broken)).toEqual(['extra']);
    const empty = buildPlan({
      namespace: '',
      snapshot: 'abc',
      customers: [{ id: 'x', name: ' ' }],
      formCustomers: {},
      connectionCustomers: {},
      keys: [],
      keyCustomers: {},
      extra: '[]',
    });
    expect(
      mappingIssues({
        ...empty,
        formIds: [F1],
        connectionIds: [C1],
        keys,
        expectedSchema: '',
        sourceChanged: true,
      }),
    ).toEqual([
      'source',
      'customer',
      'name',
      'forms',
      'namespace',
      'snapshot',
      'schema',
      'connections',
      'keys',
      'extra',
    ]);
  });
});

describe('Warnungen zu Schlüsseln der Einsendungen', () => {
  const keys = [key('aaaaaaaaaaaaaaaa', 'aktiv', 1), key('dddddddddddddddd', 'andere', 2)];
  it('fehlende, nicht übernehmbare und fremde kids mit Zählern', () => {
    const usage = [
      use('aaaaaaaaaaaaaaaa', 4, [F1, F2]),
      use('9999999999999999', 2, [F1], false),
      use('dddddddddddddddd', 1, [F1]),
    ];
    const w = keyWarnings(keys, usage, {
      keyCustomers: { aaaaaaaaaaaaaaaa: A },
      formCustomers: { [F1]: A, [F2]: B },
    });
    expect(w.missing.map((u) => u.kid)).toEqual(['9999999999999999']);
    expect(w.unusable.map((u) => u.kid)).toEqual(['dddddddddddddddd']);
    expect(w.foreign.map((u) => u.kid)).toEqual(['aaaaaaaaaaaaaaaa']);
    expect(w.affectedSubmissions).toBe(7);
  });
  it('ohne Probleme keine Warnung', () => {
    const w = keyWarnings(keys, [use('aaaaaaaaaaaaaaaa', 4, [F1])], {
      keyCustomers: { aaaaaaaaaaaaaaaa: A },
      formCustomers: { [F1]: A },
    });
    expect(w.affectedSubmissions).toBe(0);
  });
});

describe('Quellnamespace', () => {
  it('stabil aus dem Datenbanknamen, nur erlaubte Zeichen, höchstens 64', () => {
    expect(suggestNamespace('db.example', 'kubus_alt')).toBe('legacy-kubus_alt');
    expect(suggestNamespace('db.example', 'kubus_alt')).toBe(suggestNamespace('x', 'kubus_alt'));
    expect(suggestNamespace('db.example', 'mit Leer zeichen/ä')).toBe('legacy-mit-Leer-zeichen');
    expect(suggestNamespace('10.0.0.5', '  ')).toBe('legacy-10.0.0.5');
    expect(suggestNamespace('', '')).toBe('');
    expect(suggestNamespace('h', 'x'.repeat(100))).toHaveLength(64);
  });
  it('Formulare und Verbindungen der Quelle mit Namen, ältere Antworten ohne Namen', () => {
    const inventory = {
      schemaHMAC: '',
      formIds: [F1, F2],
      counts: {},
      forms: [{ id: F1, name: 'Kontakt' }],
      connectionIds: [C1],
    };
    expect(sourceForms(inventory)).toEqual([
      { id: F1, name: 'Kontakt' },
      { id: F2, name: null },
    ]);
    expect(sourceConnections(inventory)).toEqual([{ id: C1, kind: '', name: null }]);
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

describe('summarizeReport', () => {
  it('liest Tabellenzähler und offene Fälle, unbekannte Formen ergeben leere Listen', () => {
    const s = summarizeReport({
      tables: {
        formulare: { sourceCount: 3, importedCount: 3, reviewCount: 0 },
        anfragen: { sourceCount: 5, importedCount: 5, reviewCount: 1 },
      },
      issues: [{ code: 'unsupported-content', count: 1 }, { count: 2 }],
    });
    expect(s.tables.map((t) => t.table)).toEqual(['anfragen', 'formulare']);
    expect(s.tables[0]).toEqual({ table: 'anfragen', source: 5, imported: 5, review: 1 });
    expect(s.issues).toEqual([{ code: 'unsupported-content', count: 1 }]);
    expect(summarizeReport({ processed: 12 })).toEqual({ processed: 12, tables: [], issues: [] });
    expect(summarizeReport(null).tables).toEqual([]);
  });
});
