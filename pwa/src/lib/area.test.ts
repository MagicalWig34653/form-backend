import { expect, it } from 'vitest';
import {
  areaEntryCount,
  areaLabel,
  areaOf,
  areaPath,
  buildAreaGroups,
  flattenAreaOptions,
  SEARCH_THRESHOLD,
  type FormListState,
} from './area';
import { matchRoute } from './routes';
import { failedForms, scopeForms } from './stats/scope';
import { emptySnapshot } from './stats/overview';

const A = 'aaaaaaaa-1111-4111-8111-11111111111a';
const B = 'bbbbbbbb-1111-4111-8111-11111111111b';
const F1 = '11111111-1111-4111-8111-111111111111';
const F2 = '22222222-2222-4222-8222-222222222222';
const tenants = [
  { id: A, name: 'Kunde A' },
  { id: B, name: 'Straßenbau B' },
];
const item = (id: string, name: string) => ({ id, name, active: true, currentReleaseId: null });
const lists = new Map<string, FormListState>([
  [A, { status: 'ready', items: [item(F1, 'Kontakt'), item(F2, 'Angebot')], more: false }],
  [B, { status: 'error', items: [], more: false }],
]);

it('derives the area from the route only', () => {
  expect(areaOf(matchRoute('/overview'))).toEqual({ kind: 'all' });
  expect(areaOf(matchRoute('/t'))).toEqual({ kind: 'all' });
  expect(areaOf(matchRoute('/settings'))).toEqual({ kind: 'all' });
  expect(areaOf(matchRoute(`/t/${A}`))).toEqual({ kind: 'tenant', tenant: A });
  expect(areaOf(matchRoute(`/t/${A}/members`))).toEqual({ kind: 'tenant', tenant: A });
  expect(areaOf(matchRoute(`/t/${A}/f/${F1}/mail`))).toEqual({
    kind: 'form',
    tenant: A,
    form: F1,
  });
});

it('area paths round-trip through the router', () => {
  for (const path of ['/overview', `/t/${A}`, `/t/${A}/f/${F1}`])
    expect(areaPath(areaOf(matchRoute(path)))).toBe(path);
});

it('groups customers with their forms and marks failed or missing lists', () => {
  const groups = buildAreaGroups(tenants, lists);
  expect(groups.map((g) => g.head.label)).toEqual(['Kunde A', 'Straßenbau B']);
  expect(groups[0]?.forms.map((f) => f.label)).toEqual(['Kontakt', 'Angebot']);
  expect(groups[1]).toMatchObject({ failed: true, loading: false, forms: [] });
  expect(buildAreaGroups(tenants, new Map())[0]).toMatchObject({ loading: true, failed: false });
  const flat = flattenAreaOptions(groups, 'Gesamt');
  expect(flat.map((o) => o.label)).toEqual([
    'Gesamt',
    'Kunde A',
    'Kontakt',
    'Angebot',
    'Straßenbau B',
  ]);
});

it('filters accent-insensitive: a customer keeps its forms, a form keeps its customer', () => {
  const byCustomer = buildAreaGroups(tenants, lists, 'kunde');
  expect(byCustomer.map((g) => g.forms.length)).toEqual([2]);
  const byForm = buildAreaGroups(tenants, lists, 'angeb');
  expect(byForm.map((g) => [g.head.label, g.forms.map((f) => f.label)])).toEqual([
    ['Kunde A', ['Angebot']],
  ]);
  expect(buildAreaGroups(tenants, lists, 'strassen').map((g) => g.head.label)).toEqual([
    'Straßenbau B',
  ]);
  expect(flattenAreaOptions(buildAreaGroups(tenants, lists, 'zzz'), 'Gesamt', 'zzz')).toEqual([]);
  expect(flattenAreaOptions([], 'Gesamt', 'ges').map((o) => o.id)).toEqual(['area-all']);
});

it('offers search only above the threshold', () => {
  expect(areaEntryCount(tenants, lists)).toBe(5);
  expect(areaEntryCount(tenants, lists) > SEARCH_THRESHOLD).toBe(false);
  const many = Array.from({ length: SEARCH_THRESHOLD }, (_, i) => ({
    id: `t${i}`,
    name: `K${i}`,
  }));
  expect(areaEntryCount(many, new Map()) > SEARCH_THRESHOLD).toBe(true);
});

it('labels the current area, with fallbacks for unknown ids', () => {
  const text = { all: 'Gesamt', customer: 'Kunde', form: 'Formular' };
  expect(areaLabel({ kind: 'all' }, tenants, lists, text).label).toBe('Gesamt');
  expect(areaLabel({ kind: 'tenant', tenant: A }, tenants, lists, text).label).toBe('Kunde A');
  expect(areaLabel({ kind: 'form', tenant: A, form: F2 }, tenants, lists, text)).toEqual({
    label: 'Angebot',
    kind: 'form',
    tenantName: 'Kunde A',
  });
  expect(areaLabel({ kind: 'form', tenant: B, form: F1 }, tenants, lists, text).label).toBe(
    'Formular',
  );
  expect(areaLabel({ kind: 'tenant', tenant: 'x' }, tenants, lists, text).label).toBe('Kunde');
});

it('aggregation over customers: failed lists are reported, never counted as zero', () => {
  const scope = scopeForms(tenants, lists);
  expect(scope.forms.map((f) => [f.tenant, f.name])).toEqual([
    [A, 'Kunde A · Kontakt'],
    [A, 'Kunde A · Angebot'],
  ]);
  expect(scope.failed).toEqual([{ id: B, name: 'Straßenbau B' }]);
  expect(scope.more).toBe(false);
  const only = [{ id: A, name: 'Kunde A' }];
  expect(scopeForms(only, lists).forms[0]?.name).toBe('Kontakt');
  const more = scopeForms(only, new Map([[A, { status: 'ready', items: [], more: true }]]));
  expect(more.more).toBe(true);
  const ready = { ...emptySnapshot(), statsStatus: 'ready' as const };
  const snaps = new Map([
    [F1, { ...ready, detailStatus: 'ready' as const, entriesStatus: 'ready' as const }],
    [F2, { ...emptySnapshot(), statsStatus: 'error' as const }],
  ]);
  expect(failedForms(scope.forms, snaps).map((f) => f.id)).toEqual([F2]);
});
