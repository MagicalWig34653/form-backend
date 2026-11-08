import { onMount } from 'svelte';
import { router } from '$lib/router.svelte';
import { matchRoute } from '$lib/routes';
import { session } from '$lib/session.svelte';
import { accountItem, buildNav } from './nav';
import { formContext } from '$lib/formContext.svelte';
import { shellState } from './shell-state.svelte';

/** Reactive navigation model for the current route; call during component initialisation. */
export function useNav() {
  onMount(() => void shellState.loadOpsAccess(session.me?.id ?? 'anonymous'));
  const route = $derived(matchRoute(router.path));
  // Customer in focus: the route's, else the last one used, else the only one. With several customers and
  // none chosen the form entries lead to the customer list (see nav.ts needPath).
  const tenant = $derived.by(() => {
    if ('tenant' in route) return route.tenant;
    const last = formContext.last?.tenant;
    if (last && session.tenants.some((x) => x.id === last)) return last;
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
      tenant,
      manageTenant,
      systemAdministrator: session.me?.systemAdministrator === true,
      opsVisible: shellState.opsVisible,
      lastForm: formContext.last,
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
