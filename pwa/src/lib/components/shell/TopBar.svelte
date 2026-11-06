<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { tenantPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Dialog, DialogTrigger, DialogClose, DialogContent } from '$lib/components/ui/dialog';
  import Breadcrumb from '$lib/components/admin/Breadcrumb.svelte';
  import SidebarNav from './SidebarNav.svelte';
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
  let open = $state(false);
</script>

<header
  class="glass-bar border-border-subtle sticky top-0 z-30 flex min-h-[var(--topbar-h)] flex-wrap items-center gap-x-2 gap-y-2 border-b px-4 py-2 md:px-8"
>
  <div class="md:hidden">
    <Dialog bind:open
      ><DialogTrigger
        >{#snippet child({ props })}<Button
            {...props}
            variant="ghost"
            class="px-3"
            aria-label={t.shell.menu}><NavIcon name="menu" size={20} /></Button
          >{/snippet}</DialogTrigger
      ><DialogContent
        title={t.shell.navigation}
        description={t.shell.workspace}
        class="inset-y-0 left-0 h-dvh max-h-dvh w-80 max-w-[90vw] translate-x-0 translate-y-0 overflow-y-auto rounded-none p-4"
        ><div class="flex w-full flex-col">
          <SidebarNav onnavigate={() => (open = false)} /><DialogClose
            >{#snippet child({ props })}<Button {...props} variant="outline">{t.shell.close}</Button
              >{/snippet}</DialogClose
          >
        </div></DialogContent
      ></Dialog
    >
  </div>
  <Breadcrumb items={crumbs} class="min-w-0 flex-1" />
  <div class="order-last w-full md:order-none md:w-auto">
    {#if session.tenants.length > 1}
      <label
        class="border-border-subtle bg-surface-card relative flex min-h-10 items-center gap-2 rounded-[var(--r-ctl)] border pr-2 pl-1.5 text-sm shadow-[var(--shadow-card)] md:max-w-64"
        ><span
          aria-hidden="true"
          class="bg-ui-accent-soft text-ui-accent-ink flex size-7 shrink-0 items-center justify-center rounded-md text-xs font-semibold"
          >{(current?.name ?? '?').slice(0, 1).toLocaleUpperCase('de')}</span
        ><select
          aria-label={t.admin.customer}
          class="min-h-9 min-w-0 flex-1 cursor-pointer appearance-none truncate bg-transparent pr-6 font-medium outline-none"
          value={selected}
          onchange={(e) => router.navigate(tenantPath(e.currentTarget.value))}
          ><option value="" disabled>{t.shell.customers}</option
          >{#each session.tenants as tenant (tenant.id)}<option value={tenant.id}
              >{tenant.name}</option
            >{/each}</select
        ><span
          aria-hidden="true"
          class="text-muted-foreground pointer-events-none absolute right-2 rotate-90"
          ><NavIcon name="chevron" size={14} /></span
        ></label
      >
    {:else if current}
      <span
        class="border-border-subtle bg-surface-card inline-flex min-h-10 items-center gap-2 rounded-[var(--r-ctl)] border pr-3 pl-1.5 text-sm font-medium shadow-[var(--shadow-card)]"
        ><span
          aria-hidden="true"
          class="bg-ui-accent-soft text-ui-accent-ink flex size-7 items-center justify-center rounded-md text-xs font-semibold"
          >{current.name.slice(0, 1).toLocaleUpperCase('de')}</span
        ><span class="sr-only">{t.shell.customerSingle}: </span>{current.name}</span
      >
    {/if}
  </div>
  <div class="flex items-center gap-1">
    <Button
      variant="ghost"
      class="px-3 md:hidden"
      aria-label={t.palette.open}
      aria-haspopup="dialog"
      onclick={() => (shellState.paletteOpen = true)}><NavIcon name="search" size={19} /></Button
    >
    <AppearanceMenu />
    <Button
      variant="ghost"
      class="px-3"
      aria-label={t.admin.logout}
      onclick={() => void session.logout()}
      ><NavIcon name="logout" size={18} /><span class="hidden lg:inline">{t.admin.logout}</span
      ></Button
    >
  </div>
</header>
