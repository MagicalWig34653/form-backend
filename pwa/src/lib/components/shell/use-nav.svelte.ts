import { onMount } from 'svelte';
import { router } from '$lib/router.svelte';
import { matchRoute } from '$lib/routes';
import { session } from '$lib/session.svelte';
import { accountItem, buildNav } from './nav';
import { shellState } from './shell-state.svelte';

/** Reactive navigation model for the current route; call during component initialisation. */
export function useNav() {
  onMount(() => void shellState.loadOpsAccess(session.me?.id ?? 'anonymous'));
  const route = $derived(matchRoute(router.path));
  const tenant = $derived('tenant' in route ? route.tenant : session.tenants[0]?.id);
  const manageTenant = $derived(
    session.tenants.find(
      (x) => (tenant ? x.id === tenant : true) && x.permissions.includes('identity.manage'),
    )?.id,
  );
  const groups = $derived(
    buildNav({
      route,
      tenant,
      manageTenant,
      systemAdministrator: session.me?.systemAdministrator === true,
      opsVisible: shellState.opsVisible,
    }),
  );
  return {
    get route() {
      return route;
    },
    get tenant() {
      return tenant;
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
