import { expect, it } from 'vitest';
import { filterItems, groupItems, step, type PaletteItem } from './palette';
import { buildNav, crumbsFor } from './nav';
import type { Route } from '$lib/routes';

const item = (
  id: string,
  group: PaletteItem['group'],
  label: string,
  keywords?: string,
): PaletteItem => ({
  id,
  group,
  label,
  icon: 'forms',
  ...(keywords ? { keywords } : {}),
});
const items = [
  item('a', 'pages', 'Einstellungen'),
  item('b', 'forms', 'Größen-Anfrage'),
  item('c', 'actions', 'Darstellung wechseln', 'dunkel modus'),
];

it('filters accent-insensitive and requires all words', () => {
  expect(filterItems(items, 'grossen').map((i) => i.id)).toEqual(['b']);
  expect(filterItems(items, 'EINSTELL').map((i) => i.id)).toEqual(['a']);
  expect(filterItems(items, 'dunkel wechs').map((i) => i.id)).toEqual(['c']);
  expect(filterItems(items, 'dunkel zzz')).toEqual([]);
  expect(filterItems(items, '  ')).toHaveLength(3);
});

it('groups keep the given order and drop empty groups', () => {
  const grouped = groupItems(items, ['actions', 'pages', 'customers']);
  expect(grouped.map((g) => g.id)).toEqual(['actions', 'pages']);
});

it('arrow stepping wraps and handles empty lists', () => {
  expect(step(0, -1, 3)).toBe(2);
  expect(step(2, 1, 3)).toBe(0);
  expect(step(0, 1, 0)).toBe(-1);
});

const ctx = (route: Route) => ({
  route,
  tenant: 'tenant' in route ? route.tenant : undefined,
  manageTenant: undefined,
  systemAdministrator: false,
  opsVisible: false,
});

it('nav model groups pages and only offers rights-based entries when allowed', () => {
  const plain = buildNav(ctx({ name: 'tenants' }));
  expect(plain.map((g) => g.label)).toEqual(['Arbeitsbereich', 'Verwaltung']);
  const ids = plain.flatMap((g) => g.items.map((i) => i.id));
  expect(ids).not.toContain('ops');
  expect(ids).not.toContain('connections');
  expect(ids).not.toContain('members');
  const full = buildNav({
    ...ctx({ name: 'tenants' }),
    systemAdministrator: true,
    opsVisible: true,
    manageTenant: 't1',
  });
  const fullIds = full.flatMap((g) => g.items.map((i) => i.id));
  expect(fullIds).toEqual(expect.arrayContaining(['ops', 'connections', 'members']));
});

it('entries link follows the current form, otherwise explains itself', () => {
  const tenant = 'aaaaaaaa-1111-4111-8111-111111111111';
  const form = 'bbbbbbbb-1111-4111-8111-111111111111';
  const onForm = buildNav(ctx({ name: 'form', tenant, form, tab: 'overview' }));
  const entries = onForm[0]?.items.find((i) => i.id === 'entries');
  expect(entries?.href).toBe(`/t/${tenant}/f/${form}/entries`);
  expect(entries?.hint).toBeUndefined();
  const off = buildNav(ctx({ name: 'forms', tenant }))[0]?.items.find((i) => i.id === 'entries');
  expect(off?.hint).toBe('Bitte zuerst ein Formular wählen.');
});

it('entries and statistics are inactive without a form, usable with the last opened one', () => {
  const tenant = 'aaaaaaaa-1111-4111-8111-111111111111';
  const form = 'bbbbbbbb-1111-4111-8111-111111111111';
  const find = (nav: ReturnType<typeof buildNav>, id: string) =>
    nav[0]?.items.find((i) => i.id === id);
  const off = buildNav(ctx({ name: 'forms', tenant }));
  expect(find(off, 'entries')?.disabled).toBe(true);
  expect(find(off, 'statistics')?.disabled).toBe(true);
  const remembered = buildNav({ ...ctx({ name: 'forms', tenant }), lastForm: { tenant, form } });
  expect(find(remembered, 'entries')?.disabled).toBeUndefined();
  expect(find(remembered, 'entries')?.href).toBe(`/t/${tenant}/f/${form}/entries`);
  const none = buildNav(ctx({ name: 'tenants' }));
  expect(find(none, 'forms')?.disabled).toBe(true);
  expect(find(none, 'customers')?.disabled).toBeUndefined();
});

it('breadcrumbs end on the current page', () => {
  const tenants = [{ id: 't1', name: 'Kunde A' }];
  const trail = crumbsFor({ name: 'form', tenant: 't1', form: 'f1', tab: 'entries' }, tenants, []);
  expect(trail.map((c) => c.label)).toEqual(['Kunde A', 'Formulare', 'Formular', 'Einsendungen']);
  expect(trail.at(-1)?.href).toBeUndefined();
  expect(crumbsFor({ name: 'notFound' }, tenants, [])).toEqual([]);
});
