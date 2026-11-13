import { onMount } from 'svelte';
import { router } from '$lib/router.svelte';
import { matchRoute } from '$lib/routes';
import { areaOf } from '$lib/area';
import { session } from '$lib/session.svelte';
import { onboarding } from '$lib/onboarding.svelte';
import { accountItem, buildNav } from './nav';
import { shellState } from './shell-state.svelte';

/** Reactive navigation model for the current route; call during component initialisation. */
export function useNav() {
  onMount(() => void shellState.loadOpsAccess(session.me?.id ?? 'anonymous'));
  const route = $derived(matchRoute(router.path));
  const area = $derived(areaOf(route));
  // Customer in focus: the area's, else the only one of the session (never a remembered one).
  const tenant = $derived.by(() => {
    if (area.kind !== 'all') return area.tenant;
    return session.tenants.length === 1 ? session.tenants[0]?.id : undefined;
  });
  const manageTenant = $derived(
    session.tenants.find(
      (x) => (tenant ? x.id === tenant : true) && x.permissions.includes('identity.manage'),
    )?.id,
  );
  const groups = $derived(
    buildNav({
      route,
      manageTenant,
      systemAdministrator: session.me?.systemAdministrator === true,
      opsVisible: shellState.opsVisible,
      setup:
        onboarding.open && onboarding.ready
          ? { done: onboarding.progress.done, total: onboarding.progress.total }
          : null,
    }),
  );
  return {
    get route() {
      return route;
    },
    get area() {
      return area;
    },
    get tenant() {
      return tenant;
    },
    get manageTenant() {
      return manageTenant;
    },
    get groups() {
      return groups;
    },
    get account() {
      return accountItem(route);
    },
  };
}

/** Same-tab navigation for plain left clicks; modified clicks keep the browser's default. */
export function followLink(event: MouseEvent, href: string): boolean {
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
  event.preventDefault();
  router.navigate(href);
  return true;
}
