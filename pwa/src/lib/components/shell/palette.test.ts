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

const tenant = 'aaaaaaaa-1111-4111-8111-111111111111';
const form = 'bbbbbbbb-1111-4111-8111-111111111111';
const find = (nav: ReturnType<typeof buildNav>, id: string) =>
  nav[0]?.items.find((i) => i.id === id);

it('Einsendungen and Statistik follow the area: form, customer, overall', () => {
  const onForm = buildNav(ctx({ name: 'form', tenant, form, tab: 'overview' }));
  expect(find(onForm, 'entries')?.href).toBe(`/t/${tenant}/f/${form}/entries`);
  expect(find(onForm, 'statistics')?.href).toBe(`/t/${tenant}/f/${form}#statistics`);
  expect(find(onForm, 'forms')?.href).toBe(`/t/${tenant}`);
  const onTenant = buildNav(ctx({ name: 'forms', tenant }));
  expect(find(onTenant, 'entries')?.href).toBe(`/t/${tenant}#recent-entries`);
  expect(find(onTenant, 'statistics')?.href).toBe(`/t/${tenant}#statistics`);
  const members = buildNav(ctx({ name: 'members', tenant }));
  expect(find(members, 'entries')?.href).toBe(`/t/${tenant}#recent-entries`);
  for (const route of [{ name: 'overview' }, { name: 'tenants' }, { name: 'settings' }] as const) {
    const all = buildNav(ctx(route));
    expect(find(all, 'entries')?.href).toBe('/overview#recent-entries');
    expect(find(all, 'statistics')?.href).toBe('/overview#statistics');
    expect(find(all, 'dashboard')?.href).toBe('/overview');
    expect(find(all, 'forms')).toBeUndefined();
    expect(find(all, 'customers')?.href).toBe('/t');
  }
  expect(find(onTenant, 'dashboard')).toBeUndefined();
});

it('no entry is dead or disabled and none carries a need hint', () => {
  for (const route of [
    { name: 'tenants' },
    { name: 'overview' },
    { name: 'forms', tenant },
    { name: 'form', tenant, form, tab: 'entries' },
  ] as Route[])
    for (const item of buildNav(ctx(route)).flatMap((g) => g.items)) {
      expect(item).not.toHaveProperty('disabled');
      expect(item.href).not.toContain('need=');
    }
  const onEntries = buildNav(ctx({ name: 'form', tenant, form, tab: 'entries' }));
  expect(find(onEntries, 'entries')?.active).toBe(true);
  expect(find(onEntries, 'forms')?.active).toBe(false);
  expect(find(buildNav(ctx({ name: 'overview' })), 'dashboard')?.active).toBe(true);
});

it('breadcrumbs end on the current page', () => {
  const tenants = [{ id: 't1', name: 'Kunde A' }];
  const trail = crumbsFor({ name: 'form', tenant: 't1', form: 'f1', tab: 'entries' }, tenants, []);
  expect(trail.map((c) => c.label)).toEqual(['Kunde A', 'Formulare', 'Formular', 'Einsendungen']);
  expect(trail.at(-1)?.href).toBeUndefined();
  expect(crumbsFor({ name: 'notFound' }, tenants, [])).toEqual([]);
  expect(crumbsFor({ name: 'overview' }, tenants, []).map((c) => c.label)).toEqual(['Dashboard']);
});
