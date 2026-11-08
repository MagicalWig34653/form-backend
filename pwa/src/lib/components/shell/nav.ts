import { t } from '$lib/i18n';
import { formPath, tenantPath, TABS, type Route, type Tab } from '$lib/routes';
import type { Crumb } from '$lib/components/admin/Breadcrumb.svelte';

export interface NavItem {
  id: string;
  label: string;
  href: string;
  icon: string;
  active: boolean;
  /** Tooltip explaining why the target is only a fallback (e.g. no form chosen yet). */
  hint?: string;
  /** Nothing to open yet (no customer or form): shown as inactive text instead of a link that would stay on the same page. */
  disabled?: boolean;
}
export interface NavGroup {
  id: 'work' | 'admin';
  label: string;
  items: NavItem[];
}
export interface NavContext {
  route: Route;
  /** Tenant of the route, or the first tenant of the session. */
  tenant: string | undefined;
  manageTenant: string | undefined;
  systemAdministrator: boolean;
  opsVisible: boolean;
  /** Form last opened in this session; keeps "Einsendungen"/"Statistik" usable outside a form page. */
  lastForm?: { tenant: string; form: string } | undefined;
}

/** Navigation model shared by the sidebar and the command palette. */
export function buildNav(c: NavContext): NavGroup[] {
  const { route } = c;
  const forms = c.tenant ? tenantPath(c.tenant) : '/t';
  const onForm = route.name === 'form';
  const target = onForm
    ? { tenant: route.tenant, form: route.form }
    : c.lastForm && c.lastForm.tenant === c.tenant
      ? c.lastForm
      : undefined;
  const work: NavItem[] = [
    {
      id: 'customers',
      label: t.shell.customers,
      href: '/t',
      icon: 'customers',
      active: route.name === 'tenants',
    },
    {
      id: 'forms',
      label: t.shell.forms,
      href: forms,
      icon: 'forms',
      active: route.name === 'forms' || (onForm && route.tab !== 'entries'),
      ...(c.tenant ? {} : { disabled: true, hint: t.shell.noCustomer }),
    },
    {
      id: 'entries',
      label: t.shell.entries,
      href: target ? formPath(target.tenant, target.form, 'entries') : forms,
      icon: 'entries',
      active: onForm && route.tab === 'entries',
      ...(target ? {} : { hint: t.shell.chooseForm, disabled: true }),
    },
    {
      id: 'statistics',
      label: t.shell.statistics,
      href: target ? formPath(target.tenant, target.form) + '#statistics' : forms,
      icon: 'statistics',
      active: false,
      ...(target ? {} : { hint: t.shell.chooseForm, disabled: true }),
    },
  ];
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
