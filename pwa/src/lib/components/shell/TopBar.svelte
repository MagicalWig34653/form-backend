<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { tenantPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import Breadcrumb from '$lib/components/admin/Breadcrumb.svelte';
  import AppearanceMenu from './AppearanceMenu.svelte';
  import NavIcon from './NavIcon.svelte';
  import { crumbsFor } from './nav';
  import { shellState } from './shell-state.svelte';
  import { useNav } from './use-nav.svelte';

  const nav = useNav();
  const crumbs = $derived(
    crumbsFor(
      nav.route,
      session.tenants,
      nav.groups.flatMap((g) => g.items),
    ),
  );
  const current = $derived(session.tenants.find((x) => x.id === nav.tenant));
  const selected = $derived('tenant' in nav.route ? nav.route.tenant : '');
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
    {#if session.tenants.length > 1}
      <label class="relative flex items-center max-sm:hidden"
        ><span class="sr-only">{t.admin.customer}</span><select
          class="select-ctl border-input hover:bg-muted h-10 max-w-56 min-w-0 truncate rounded-lg border bg-transparent py-1 pr-9 pl-3 text-sm outline-none"
          value={selected}
          onchange={(e) => router.navigate(tenantPath(e.currentTarget.value))}
          ><option value="" disabled>{t.shell.chooseCustomer}</option
          >{#each session.tenants as tenant (tenant.id)}<option value={tenant.id}
              >{tenant.name}</option
            >{/each}</select
        ></label
      >
    {:else if current}
      <span
        class="text-muted-foreground inline-flex h-10 items-center truncate text-sm max-sm:hidden"
        ><span class="sr-only">{t.shell.customerSingle}: </span>{current.name}</span
      >
    {/if}
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
