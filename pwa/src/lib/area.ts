import { formPath, OVERVIEW_PATH, tenantPath, type Route } from '$lib/routes';
import type { FormListItem, Tenant } from '$lib/api/admin';

/** The scope that dashboard, submissions and statistics are cut to. Derived from the route only. */
export type Area =
  | { kind: 'all' }
  | { kind: 'tenant'; tenant: string }
  | { kind: 'form'; tenant: string; form: string };

/** Routes below a customer or form belong to it; every other page counts as "all". */
export function areaOf(route: Route): Area {
  switch (route.name) {
    case 'forms':
    case 'members':
      return { kind: 'tenant', tenant: route.tenant };
    case 'form':
      return { kind: 'form', tenant: route.tenant, form: route.form };
    default:
      return { kind: 'all' };
  }
}

export const areaPath = (area: Area): string =>
  area.kind === 'all'
    ? OVERVIEW_PATH
    : area.kind === 'tenant'
      ? tenantPath(area.tenant)
      : formPath(area.tenant, area.form);

export interface AreaOption {
  /** Stable id, also used for the DOM id. */
  id: string;
  area: Area;
  label: string;
  /** Name of the customer the option belongs to (customers themselves: own name). */
  tenantName: string;
}
export interface AreaGroup {
  /** Customer id. */
  id: string;
  head: AreaOption;
  forms: AreaOption[];
  /** The form list of this customer could not be loaded. */
  failed: boolean;
  loading: boolean;
}
export interface FormListState {
  status: 'loading' | 'ready' | 'error';
  items: FormListItem[];
  more: boolean;
}

const fold = (text: string): string =>
  text.toLocaleLowerCase('de').normalize('NFD').replace(/\p{M}/gu, '').replace(/ß/g, 'ss');
const words = (query: string): string[] => fold(query).split(/\s+/).filter(Boolean);

/** Above this many entries the menu gets a search field. */
export const SEARCH_THRESHOLD = 8;

/**
 * Customer groups for the area menu. A matching customer keeps all its forms,
 * a matching form keeps its customer; without a query everything is shown.
 */
export function buildAreaGroups(
  tenants: readonly Pick<Tenant, 'id' | 'name'>[],
  lists: ReadonlyMap<string, FormListState>,
  query = '',
): AreaGroup[] {
  const w = words(query);
  const matches = (text: string) => w.every((x) => fold(text).includes(x));
  const out: AreaGroup[] = [];
  for (const c of tenants) {
    const list = lists.get(c.id);
    const head: AreaOption = {
      id: `area-${c.id}`,
      area: { kind: 'tenant', tenant: c.id },
      label: c.name,
      tenantName: c.name,
    };
    const forms: AreaOption[] = (list?.items ?? []).map((f) => ({
      id: `area-${c.id}-${f.id}`,
      area: { kind: 'form', tenant: c.id, form: f.id },
      label: f.name,
      tenantName: c.name,
    }));
    const own = w.length === 0 || matches(c.name);
    const shown = own ? forms : forms.filter((f) => matches(f.label));
    if (!own && shown.length === 0) continue;
    out.push({
      id: c.id,
      head,
      forms: shown,
      failed: list?.status === 'error',
      loading: list === undefined || list.status === 'loading',
    });
  }
  return out;
}

/** Selectable options in display order: "all" first (if it matches), then each customer followed by its forms. */
export function flattenAreaOptions(
  groups: readonly AreaGroup[],
  allLabel: string,
  query = '',
): AreaOption[] {
  const list: AreaOption[] = [];
  if (words(query).every((x) => fold(allLabel).includes(x)))
    list.push({ id: 'area-all', area: { kind: 'all' }, label: allLabel, tenantName: allLabel });
  for (const g of groups) list.push(g.head, ...g.forms);
  return list;
}

/** Number of entries the menu would show without a filter. */
export const areaEntryCount = (
  tenants: readonly unknown[],
  lists: ReadonlyMap<string, FormListState>,
): number => 1 + tenants.length + [...lists.values()].reduce((n, l) => n + l.items.length, 0);

/** Label of the current area for the closed menu; unknown ids fall back to a generic text. */
export function areaLabel(
  area: Area,
  tenants: readonly Pick<Tenant, 'id' | 'name'>[],
  lists: ReadonlyMap<string, FormListState>,
  text: { all: string; customer: string; form: string },
): { label: string; kind: Area['kind']; tenantName?: string } {
  if (area.kind === 'all') return { label: text.all, kind: 'all' };
  const tenant = tenants.find((x) => x.id === area.tenant)?.name ?? text.customer;
  if (area.kind === 'tenant') return { label: tenant, kind: 'tenant', tenantName: tenant };
  const form = lists.get(area.tenant)?.items.find((f) => f.id === area.form)?.name ?? text.form;
  return { label: form, kind: 'form', tenantName: tenant };
}
