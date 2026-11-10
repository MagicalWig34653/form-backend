<script lang="ts">
  import { t } from '$lib/i18n';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import Breadcrumb from '$lib/components/admin/Breadcrumb.svelte';
  import AppearanceMenu from './AppearanceMenu.svelte';
  import NavIcon from './NavIcon.svelte';
  import { crumbsFor } from './nav';
  import { shellState } from './shell-state.svelte';
  import { useNav } from './use-nav.svelte';

  const nav = useNav();
  // Wie im thermoctl-Design beginnt der Pfad mit dem Namen der Anwendung.
  const crumbs = $derived([
    { label: t.app.name, href: '/t' },
    ...crumbsFor(
      nav.route,
      session.tenants,
      nav.groups.flatMap((g) => g.items),
    ),
  ]);
</script>

<header
  class="app-topbar sticky top-0 z-20 flex min-h-[60px] items-center justify-between gap-3 border-b px-4 py-2 sm:px-7"
>
  <div class="flex min-w-0 flex-1 items-center gap-2">
    <Button
      id="drawer-trigger"
      variant="ghost"
      size="icon"
      class="lg:hidden"
      aria-label={t.shell.menu}
      aria-expanded={shellState.drawerOpen}
      aria-controls="app-sidebar"
      onclick={() => (shellState.drawerOpen = !shellState.drawerOpen)}
      ><NavIcon name="panel" size={18} /></Button
    >
    <Breadcrumb items={crumbs} class="min-w-0" />
  </div>
  <div class="flex items-center gap-1">
    <Button
      variant="ghost"
      size="icon"
      class="lg:hidden"
      aria-label={t.palette.open}
      aria-haspopup="dialog"
      onclick={() => (shellState.paletteOpen = true)}><NavIcon name="search" size={18} /></Button
    >
    <AppearanceMenu />
  </div>
</header>
