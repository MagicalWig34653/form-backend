<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { matchRoute } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Sheet, SheetContent } from '$lib/components/ui/sheet';
  import Overview from './Overview.svelte';
  import Tenants from './Tenants.svelte';
  import Forms from './Forms.svelte';
  import FormDirectory from './FormDirectory.svelte';
  import FormPage from './FormPage.svelte';
  import Connections from './Connections.svelte';
  import Account from './Account.svelte';
  import ApiTokens from './ApiTokens.svelte';
  import Settings from './Settings.svelte';
  import Ops from './Ops.svelte';
  import Installation from './Installation.svelte';
  import Migration from './Migration.svelte';
  import { http } from '$lib/api';
  import Members from './Members.svelte';
  import SidebarNav from '$lib/components/shell/SidebarNav.svelte';
  import VersionInfo from '$lib/components/shell/VersionInfo.svelte';
  import TopBar from '$lib/components/shell/TopBar.svelte';
  import CommandPalette from '$lib/components/shell/CommandPalette.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NotFound from '../NotFound.svelte';
  import { shellState } from '$lib/components/shell/shell-state.svelte';

  const route = $derived(matchRoute(router.path));
  onMount(() => {
    void session.load().then(async () => {
      if (session.status !== 'ready') return;
      const r = await http.request<{ required: boolean }>('GET', '/setup-state');
      if (
        r.ok &&
        r.data.required &&
        !['installation', 'migration', 'connections', 'settings', 'account', 'apiTokens'].includes(
          route.name,
        )
      )
        router.navigate('/installation');
    });
  });

  // Below 1024 px the navigation is a sheet: closed by default, closed again on every page change.
  // The sidebar exists once: fixed on desktop, inside the sheet below 1024 px (no duplicate ids).
  let desktop = $state(window.matchMedia('(min-width: 1024px)').matches);
  $effect(() => {
    const media = window.matchMedia('(min-width: 1024px)');
    const update = () => {
      desktop = media.matches;
      if (media.matches) shellState.drawerOpen = false;
    };
    update();
    media.addEventListener('change', update);
    return () => media.removeEventListener('change', update);
  });
  $effect(() => {
    void router.path;
    shellState.drawerOpen = false;
  });
  // The sheet opens on its first entry (not on the area selector) so the menu can be read from the top.
  function focusFirstEntry(event: Event): void {
    event.preventDefault();
    document.querySelector<HTMLElement>('[data-slot="sheet-content"] [data-nav-item]')?.focus();
  }

  // Not signed in: to the login page, remembering where the user wanted to go.
  $effect(() => {
    if (session.status === 'anonymous')
      router.navigate(`/login?next=${encodeURIComponent(router.path)}`, true);
  });
</script>

{#if session.status === 'loading'}
  <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4 sm:p-7" aria-busy="true">
    <p role="status" class="text-muted-foreground text-sm">
      {t.admin.loading}
    </p>
    <Skeleton class="h-8 w-48" />
    <Skeleton class="h-24 w-full rounded-xl" />
    <Skeleton class="h-48 w-full rounded-xl" />
  </div>
{:else if session.status === 'error'}
  <div class="mx-auto flex max-w-5xl flex-col items-start gap-3 p-4 sm:p-7">
    <Banner tone="danger" class="w-full">
      {session.error?.message}
      {#snippet action()}
        <Button type="button" onclick={() => void session.load()}>{t.admin.retry}</Button>
      {/snippet}
    </Banner>
  </div>
{:else if session.status === 'ready'}
  {#if desktop}
    <aside
      id="app-sidebar"
      class="app-sidebar bg-sidebar fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r px-3 py-4"
    >
      <SidebarNav />
    </aside>
  {/if}
  <Sheet bind:open={shellState.drawerOpen}>
    <SheetContent
      side="left"
      title={t.shell.navigation}
      hideHeader
      onOpenAutoFocus={focusFirstEntry}
      class="bg-sidebar text-foreground px-3 py-4"
    >
      <SidebarNav onnavigate={() => (shellState.drawerOpen = false)} />
    </SheetContent>
  </Sheet>
  <div class="min-h-dvh lg:pl-64">
    <TopBar />
    <CommandPalette />
    <div class="mx-auto flex w-full max-w-6xl min-w-0 flex-col gap-6 px-4 py-6 sm:px-7 sm:py-8">
      {#if route.name === 'overview'}
        <Overview />
      {:else if route.name === 'tenants'}
        <Tenants />
      {:else if route.name === 'formDirectory'}
        <FormDirectory />
      {:else if route.name === 'forms'}
        {#key route.tenant}<Forms tenant={route.tenant} />{/key}
      {:else if route.name === 'form'}
        {#key `${route.tenant}/${route.form}`}<FormPage
            tenant={route.tenant}
            form={route.form}
            tab={route.tab}
          />{/key}
      {:else if route.name === 'connections'}
        <Connections />
      {:else if route.name === 'apiTokens'}
        <ApiTokens />
      {:else if route.name === 'ops'}
        <Ops />
      {:else if route.name === 'installation'}
        <Installation />
      {:else if route.name === 'migration'}
        <Migration />
      {:else if route.name === 'settings'}
        <Settings />
      {:else if route.name === 'account'}
        <Account />
      {:else if route.name === 'members'}
        {#key route.tenant}<Members tenant={route.tenant} />{/key}
      {:else}
        <NotFound />
      {/if}
    </div>
    <footer
      class="text-muted-foreground mx-auto flex w-full max-w-6xl flex-wrap items-center gap-x-3 gap-y-1 px-4 pb-6 text-xs sm:px-7"
    >
      <span>{t.shell.footerLicense}</span><VersionInfo />
    </footer>
  </div>
{/if}
