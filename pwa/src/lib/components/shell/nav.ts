import { t } from '$lib/i18n';
import {
  formDirectoryPath,
  formPath,
  FORM_DIRECTORY_PATH,
  OVERVIEW_PATH,
  tenantPath,
  TABS,
  type Route,
  type Tab,
} from '$lib/routes';
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
  id: 'area' | 'manage' | 'system';
  label: string;
  items: NavItem[];
}
export interface NavContext {
  route: Route;
  /** Customer whose members page is offered (palette); the area's customer, else the only one of the session. */
  manageTenant: string | undefined;
  systemAdministrator: boolean;
  opsVisible: boolean;
  /** Open setup (done of total steps); adds the "continue setup" entry until the setup is finished. */
  setup?: { done: number; total: number } | null;
}

/** What the user has to choose first; the target page shows a matching hint (see NeedHint). */
export type Need = 'customer' | 'entries' | 'statistics';

/**
 * Navigation model shared by the sidebar and the command palette.
 * - "Bereich" follows the area derived from the route (area.ts): overall, one customer or one form.
 * - "Verwalten" lists directories that do not depend on the area; "Formulare" is pre-filtered to the area's customer.
 * - "System" exists only for system administration (and the operations page for whoever may see it).
 */
export function buildNav(c: NavContext): NavGroup[] {
  const { route } = c;
  const area = areaOf(route);
  const base = area.kind === 'all' ? OVERVIEW_PATH : tenantPath(area.tenant);
  const onForm = route.name === 'form';
  const dashboardHref = area.kind === 'form' ? formPath(area.tenant, area.form) : base;
  const entriesHref =
    area.kind === 'form' ? formPath(area.tenant, area.form, 'entries') : `${base}#recent-entries`;
  const statisticsHref =
    area.kind === 'form' ? `${formPath(area.tenant, area.form)}#statistics` : `${base}#statistics`;
  const areaItems: NavItem[] = [
    {
      id: 'dashboard',
      label: t.area.dashboard,
      href: dashboardHref,
      icon: 'dashboard',
      active: route.name === 'overview' || (onForm && route.tab !== 'entries'),
    },
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
  ];
  if (c.setup && c.systemAdministrator)
    areaItems.unshift({
      id: 'setup',
      label: t.installationPage.nav
        .replace('{n}', String(c.setup.done))
        .replace('{m}', String(c.setup.total)),
      href: '/installation',
      icon: 'setup',
      active: route.name === 'installation',
      hint: t.installationPage.navHint,
    });
  const manage: NavItem[] = [
    {
      id: 'customers',
      label: t.shell.customers,
      href: '/t',
      icon: 'customers',
      active: route.name === 'tenants' || route.name === 'forms' || route.name === 'members',
    },
    {
      id: 'forms',
      label: t.shell.forms,
      href: area.kind === 'all' ? FORM_DIRECTORY_PATH : formDirectoryPath(area.tenant),
      icon: 'forms',
      active: route.name === 'formDirectory',
    },
    {
      id: 'tokens',
      label: t.shell.tokens,
      href: '/api-tokens',
      icon: 'tokens',
      active: route.name === 'apiTokens',
    },
  ];
  const system: NavItem[] = [];
  if (c.systemAdministrator)
    system.push({
      id: 'connections',
      label: t.admin.nav.connections,
      href: '/connections',
      icon: 'connections',
      active: route.name === 'connections',
    });
  if (c.systemAdministrator)
    system.push({
      id: 'accounts',
      label: t.admin.nav.accounts,
      href: '/accounts',
      icon: 'members',
      active: route.name === 'accounts',
    });
  // The operations page stays listed (and marked) while it is open, even before its access check ran.
  if (c.opsVisible || route.name === 'ops')
    system.push({
      id: 'ops',
      label: t.ops.title,
      href: '/ops',
      icon: 'ops',
      active: route.name === 'ops',
    });
  if (c.systemAdministrator)
    system.push(
      {
        id: 'settings',
        label: t.admin.settings.title,
        href: '/settings',
        icon: 'settings',
        active: route.name === 'settings',
      },
      ...(c.setup
        ? []
        : [
            {
              id: 'installation',
              label: t.shell.setup,
              href: '/installation',
              icon: 'setup',
              active: route.name === 'installation',
            },
          ]),
      {
        id: 'migration',
        label: t.shell.migration,
        href: '/migration',
        icon: 'migration',
        active: route.name === 'migration',
      },
    );
  const groups: NavGroup[] = [
    { id: 'area', label: t.shell.groups.area, items: areaItems },
    { id: 'manage', label: t.shell.groups.manage, items: manage },
  ];
  if (system.length > 0) groups.push({ id: 'system', label: t.shell.groups.system, items: system });
  return groups;
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
    case 'formDirectory':
      return [{ label: t.shell.forms }];
    case 'overview':
      return [{ label: t.area.dashboard }];
    case 'forms':
      return [{ label: t.shell.customers, href: '/t' }, { label: tenantName(route.tenant) }];
    case 'form': {
      const trail: Crumb[] = [
        { label: tenantName(route.tenant), href: tenantPath(route.tenant) },
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
        { label: t.shell.customers, href: '/t' },
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
