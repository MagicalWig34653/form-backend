<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { matchRoute } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import Tenants from './Tenants.svelte';
  import Forms from './Forms.svelte';
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
  import TopBar from '$lib/components/shell/TopBar.svelte';
  import CommandPalette from '$lib/components/shell/CommandPalette.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NotFound from '../NotFound.svelte';

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

  // Not signed in: to the login page, remembering where the user wanted to go.
  $effect(() => {
    if (session.status === 'anonymous')
      router.navigate(`/login?next=${encodeURIComponent(router.path)}`, true);
  });
</script>

{#if session.status === 'loading'}
  <div class="mx-auto flex max-w-5xl flex-col gap-4 p-4 md:p-8" aria-busy="true">
    <p role="status" class="text-muted-foreground text-[length:var(--fs-small)]">
      {t.admin.loading}
    </p>
    <Skeleton class="h-8 w-48" />
    <Skeleton class="h-24 w-full rounded-[var(--r-card)]" />
    <Skeleton class="h-48 w-full rounded-[var(--r-card)]" />
  </div>
{:else if session.status === 'error'}
  <div class="mx-auto flex max-w-5xl flex-col items-start gap-3 p-4 md:p-8">
    <Banner tone="danger" class="w-full">
      {session.error?.message}
      {#snippet action()}
        <Button type="button" onclick={() => void session.load()}>{t.admin.retry}</Button>
      {/snippet}
    </Banner>
  </div>
{:else if session.status === 'ready'}
  <div class="min-h-dvh md:pl-[var(--sidebar-w)]">
    <aside
      class="bg-sidebar border-border-subtle fixed inset-y-0 left-0 hidden w-[var(--sidebar-w)] overflow-y-auto border-r md:block"
    >
      <SidebarNav />
    </aside>
    <TopBar />
    <CommandPalette />
    <div class="mx-auto flex max-w-[77.5rem] min-w-0 flex-col gap-6 px-4 py-8 md:px-8">
      {#if route.name === 'tenants'}
        <Tenants />
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
  </div>
{/if}
