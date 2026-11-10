import { t } from '$lib/i18n';
import { formPath, OVERVIEW_PATH, tenantPath, TABS, type Route, type Tab } from '$lib/routes';
import { areaOf } from '$lib/area';
import type { Crumb } from '$lib/components/admin/Breadcrumb.svelte';

export interface NavItem {
  id: string;
  label: string;
  href: string;
  icon: string;
  active: boolean;
  /** Tooltip explaining where the entry leads. */
  hint?: string;
}
export interface NavGroup {
  id: 'work' | 'admin';
  label: string;
  items: NavItem[];
}
export interface NavContext {
  route: Route;
  /** Customer whose members page is offered; the area's customer, else the only one of the session. */
  manageTenant: string | undefined;
  systemAdministrator: boolean;
  opsVisible: boolean;
}

/** What the user has to choose first; the target page shows a matching hint (see NeedHint). */
export type Need = 'customer' | 'entries' | 'statistics';
export const needPath = (path: string, need: Need): string => `${path}?need=${need}`;

/**
 * Navigation model shared by the sidebar and the command palette. "Einsendungen" and "Statistik"
 * follow the area derived from the route (area.ts): overall, one customer or one form.
 */
export function buildNav(c: NavContext): NavGroup[] {
  const { route } = c;
  const area = areaOf(route);
  const base = area.kind === 'all' ? OVERVIEW_PATH : tenantPath(area.tenant);
  const onForm = route.name === 'form';
  const entriesHref =
    area.kind === 'form' ? formPath(area.tenant, area.form, 'entries') : `${base}#recent-entries`;
  const statisticsHref =
    area.kind === 'form' ? `${formPath(area.tenant, area.form)}#statistics` : `${base}#statistics`;
  const work: NavItem[] = [];
  if (area.kind === 'all')
    work.push({
      id: 'dashboard',
      label: t.area.dashboard,
      href: OVERVIEW_PATH,
      icon: 'dashboard',
      active: route.name === 'overview',
    });
  work.push({
    id: 'customers',
    label: t.shell.customers,
    href: '/t',
    icon: 'customers',
    active: route.name === 'tenants',
  });
  if (area.kind !== 'all')
    work.push({
      id: 'forms',
      label: t.shell.forms,
      href: tenantPath(area.tenant),
      icon: 'forms',
      active: route.name === 'forms' || (onForm && route.tab !== 'entries'),
    });
  work.push(
    {
      id: 'entries',
      label: t.shell.entries,
      href: entriesHref,
      icon: 'entries',
      active: onForm && route.tab === 'entries',
    },
    {
      id: 'statistics',
      label: t.shell.statistics,
      href: statisticsHref,
      icon: 'statistics',
      active: false,
    },
  );
  const admin: NavItem[] = [];
  if (c.manageTenant)
    admin.push({
      id: 'members',
      label: t.admin.nav.members,
      href: `/t/${c.manageTenant}/members`,
      icon: 'members',
      active: route.name === 'members',
    });
  if (c.systemAdministrator)
    admin.push({
      id: 'connections',
      label: t.admin.nav.connections,
      href: '/connections',
      icon: 'connections',
      active: route.name === 'connections',
    });
  admin.push({
    id: 'tokens',
    label: t.shell.tokens,
    href: '/api-tokens',
    icon: 'tokens',
    active: route.name === 'apiTokens',
  });
  if (c.opsVisible)
    admin.push({
      id: 'ops',
      label: t.ops.title,
      href: '/ops',
      icon: 'ops',
      active: route.name === 'ops',
    });
  admin.push(
    {
      id: 'settings',
      label: t.admin.settings.title,
      href: '/settings',
      icon: 'settings',
      active: route.name === 'settings',
    },
    {
      id: 'installation',
      label: t.shell.setup,
      href: '/installation',
      icon: 'setup',
      active: route.name === 'installation',
    },
    {
      id: 'migration',
      label: t.shell.migration,
      href: '/migration',
      icon: 'migration',
      active: route.name === 'migration',
    },
  );
  return [
    { id: 'work', label: t.shell.groups.work, items: work },
    { id: 'admin', label: t.shell.groups.admin, items: admin },
  ];
}

/** Account entry shown at the foot of the sidebar. */
export function accountItem(route: Route): NavItem {
  return {
    id: 'account',
    label: t.admin.nav.account,
    href: '/account',
    icon: 'account',
    active: route.name === 'account',
  };
}

const tabLabel = (tab: Tab): string => t.shell.tabs[tab];

/** Breadcrumb trail for the top bar. Form names are not known to the shell, hence the generic label. */
export function crumbsFor(
  route: Route,
  tenants: readonly { id: string; name: string }[],
  nav: readonly NavItem[],
): Crumb[] {
  const tenantName = (id: string) => tenants.find((x) => x.id === id)?.name ?? t.shell.customer;
  switch (route.name) {
    case 'tenants':
      return [{ label: t.shell.customers }];
    case 'overview':
      return [{ label: t.area.dashboard }];
    case 'forms':
      return [
        { label: tenantName(route.tenant), href: tenantPath(route.tenant) },
        { label: t.shell.forms },
      ];
    case 'form': {
      const trail: Crumb[] = [
        { label: tenantName(route.tenant), href: tenantPath(route.tenant) },
        { label: t.shell.forms, href: tenantPath(route.tenant) },
        route.tab === 'overview'
          ? { label: t.shell.pageForm }
          : { label: t.shell.pageForm, href: formPath(route.tenant, route.form) },
      ];
      if (route.tab !== 'overview' && (TABS as readonly string[]).includes(route.tab))
        trail.push({ label: tabLabel(route.tab) });
      return trail;
    }
    case 'members':
      return [
        { label: tenantName(route.tenant), href: tenantPath(route.tenant) },
        { label: t.admin.nav.members },
      ];
    case 'account':
      return [{ label: t.admin.nav.account }];
    case 'notFound':
    case 'login':
    case 'setup':
      return [];
    default: {
      const own = nav.find((i) => i.active);
      return own ? [{ label: own.label }] : [];
    }
  }
}
