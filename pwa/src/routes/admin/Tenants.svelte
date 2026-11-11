<script lang="ts">
  import { rightsOf } from '$lib/admin/rights';
  import { onMount, onDestroy } from 'svelte';
  import type { Tenant } from '$lib/api/admin';
  import DataTable, { type Column } from '$lib/components/admin/DataTable.svelte';
  import FilterBar from '$lib/components/admin/FilterBar.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import NeedHint from '$lib/components/admin/NeedHint.svelte';
  import { Card, CardContent } from '$lib/components/ui/card';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { tenantPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import SearchField from '$lib/components/admin/SearchField.svelte';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  let listEl = $state<HTMLElement | undefined>();
  let name = $state('');
  let busy = $state(false);
  let message = $state('');

  let items = $state<Tenant[] | null>(null);
  let query = $state('');
  let showCreate = $state(false);
  let loading = $state(true);
  let slow = $state(false);
  let loadError = $state('');
  let pending = $state<{ id: string; name: string } | null>(null);
  let incomplete = $state(false);
  let controller: AbortController | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const visible = $derived(
    (items ?? []).filter((c) =>
      c.name.toLocaleLowerCase('de').includes(query.trim().toLocaleLowerCase('de')),
    ),
  );
  // Real data only: the rights column exists when the API reports customer-wide rights.
  const hasRights = $derived((items ?? []).some((c) => c.permissions.length > 0));
  const columns = $derived<Column[]>([
    { id: 'name', header: t.lists.name },
    ...(hasRights ? [{ id: 'rights', header: t.listUi.rights, hideBelow: 'sm' as const }] : []),
  ]);
  /** Two initials (first letters of the first two words, else the first two letters). */
  function initials(name: string): string {
    const words = name.trim().split(/\s+/);
    const raw =
      words.length > 1 ? (words[0]?.[0] ?? '') + (words[1]?.[0] ?? '') : name.trim().slice(0, 2);
    return raw.toLocaleUpperCase('de');
  }
  async function load(): Promise<void> {
    controller?.abort();
    clearTimeout(timer);
    const request = new AbortController();
    controller = request;
    loading = true;
    slow = false;
    loadError = '';
    timer = setTimeout(() => {
      slow = true;
    }, 3000);
    const r = await adminApi.tenants(request.signal);
    if (request.signal.aborted) return;
    clearTimeout(timer);
    loading = false;
    if (r.ok) items = r.data.items;
    else if (!handleSessionError(r.error))
      loadError = r.error.status === 403 ? t.lists.forbidden : t.lists.failed;
  }
  onMount(() => void load());
  onDestroy(() => {
    controller?.abort();
    clearTimeout(timer);
  });

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || !session.me?.systemAdministrator || (!pending && !name.trim())) return;
    busy = true;
    message = '';
    incomplete = false;
    try {
      if (!pending) {
        const r = await adminApi.createTenant(name.trim());
        if (!r.ok) {
          if (needsFreshLogin(r.error)) return void (await reauthenticate('/t'));
          if (!handleSessionError(r.error)) message = describeError(r.error);
          return;
        }
        pending = { id: r.data.id, name: name.trim() };
        items = [...(items ?? []), { ...pending, permissions: [] }];
      }
      try {
        await accessAutomation.ensureCustomer(pending.id);
      } catch (error) {
        incomplete = true;
        message = (error as Error).message;
        await session.refreshTenants();
        return;
      }
      await session.refreshTenants();
      router.navigate(tenantPath(pending.id));
    } finally {
      busy = false;
    }
  }
</script>

<section class="flex min-w-0 flex-col gap-5">
  <PageHeader title={t.admin.tenants.title} description={t.lists.intro} compactActions>
    {#snippet actions()}
      {#if session.me?.systemAdministrator && !(items !== null && items.length === 0 && !showCreate)}<Button
          onclick={() => {
            showCreate = true;
          }}>{t.lists.createCustomer}</Button
        >{/if}
    {/snippet}
  </PageHeader>
  <AccessStatus />
  <NeedHint accepts={['customer']} onshown={() => setTimeout(() => listEl?.focus(), 80)} />
  {#if items !== null && items.length === 0 && session.me?.systemAdministrator && !showCreate}
    <Card data-testid="first-customer" class="[--card-spacing:--spacing(6)]">
      <CardContent class="flex flex-wrap items-center gap-x-6 gap-y-4">
        <span
          aria-hidden="true"
          class="bg-brand-soft text-brand-ink flex size-12 shrink-0 items-center justify-center rounded-xl"
          ><NavIcon name="customers" size={24} /></span
        >
        <div class="min-w-0 flex-1 basis-72">
          <h2 class="mb-1 text-[21px]">{t.shell.firstCustomerTitle}</h2>
          <p class="ops-lead mb-0">{t.shell.firstCustomerBody}</p>
          <p class="ops-lead mt-1 mb-0">
            {t.shell.firstCustomerSetup}
            <a
              href="/installation"
              class="text-brand-ink underline underline-offset-4"
              onclick={(e) => {
                e.preventDefault();
                router.navigate('/installation');
              }}>{t.shell.setup}</a
            >.
          </p>
        </div>
        <Button size="lg" onclick={() => (showCreate = true)}>{t.lists.createCustomer}</Button>
      </CardContent>
    </Card>
  {/if}
  <FilterBar collapsible={false} activeCount={query.trim() ? 1 : 0} onreset={() => (query = '')}>
    <SearchField
      id="customer-search"
      label={t.lists.searchCustomers}
      placeholder={t.lists.searchCustomersPlaceholder}
      bind:value={query}
    />
    {#snippet trailing()}
      {#if items !== null}<span
          class="text-muted-foreground flex min-h-10 items-center text-sm tabular-nums"
          >{items.length === 1
            ? t.listUi.customerCountOne
            : t.listUi.customerCount.replace('{n}', String(items.length))}</span
        >{/if}
    {/snippet}
  </FilterBar>
  <div role="status" class="text-muted-foreground text-sm empty:hidden">
    {loading ? (slow ? t.lists.slow : t.admin.loading) : ''}
  </div>
  {#if loadError}
    <Banner tone="danger">
      {loadError}
      {#snippet action()}
        <Button variant="outline" onclick={() => void load()}>{t.lists.retry}</Button>
      {/snippet}
    </Banner>
  {/if}
  <Panel flush>
    <div
      bind:this={listEl}
      tabindex="-1"
      aria-busy={loading}
      class={`outline-none ${loading && items === null ? 'min-h-48' : ''}`}
    >
      {#if loading && items === null}
        <div class="flex flex-col gap-3 p-4" aria-hidden="true">
          {#each [1, 2, 3] as n (n)}<Skeleton class="h-11 rounded-md" />{/each}
        </div>
      {:else if items !== null && items.length === 0}
        <EmptyState
          icon="customers"
          title={session.me?.systemAdministrator ? t.lists.noCustomers : t.lists.noAccess}
        />
      {:else if items !== null && visible.length === 0}
        <EmptyState icon="search" title={t.lists.noCustomerMatches}>
          {#snippet action()}
            <Button
              variant="outline"
              onclick={() => {
                query = '';
              }}>{t.lists.reset}</Button
            >
          {/snippet}
        </EmptyState>
      {:else if items !== null}
        <DataTable
          label={t.admin.tenants.title}
          {columns}
          rows={visible}
          rowKey={(c) => c.id}
          rowHref={(c) => tenantPath(c.id)}
        >
          {#snippet cell(c, column)}
            {#if column.id === 'name'}
              <span class="flex min-w-0 items-center gap-3">
                <span
                  aria-hidden="true"
                  class="bg-brand-soft text-brand-ink ring-brand-ink/30 flex size-8 shrink-0 items-center justify-center rounded-full text-sm font-semibold ring-1"
                  >{initials(c.name)}</span
                >
                <a
                  class="min-w-0 break-words underline-offset-4 hover:underline"
                  aria-label={`${t.lists.open}: ${c.name}`}
                  href={tenantPath(c.id)}
                  onclick={(e) => {
                    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
                    e.preventDefault();
                    router.navigate(tenantPath(c.id));
                  }}>{c.name}</a
                >
                {#if pending?.id === c.id && (busy || incomplete)}
                  <StatusChip
                    tone={busy ? 'info' : 'warn'}
                    pulse={busy}
                    label={busy ? t.lists.preparing : t.lists.incomplete}
                  />
                {/if}
              </span>
            {:else if column.id === 'rights'}
              <ul
                class="flex flex-wrap gap-1.5"
                data-testid="rights-chips"
                aria-label={t.listUi.rights}
              >
                {#each rightsOf(c.permissions) as right (right)}
                  <li class="bg-muted text-muted-foreground rounded-full px-2 py-0.5 text-xs">
                    {right}
                  </li>
                {/each}
              </ul>
            {/if}
          {/snippet}
        </DataTable>
      {/if}
    </div>
  </Panel>
  {#if session.me?.systemAdministrator && showCreate}
    <form onsubmit={(e) => void create(e)} aria-busy={busy}>
      <Panel title={t.lists.createCustomer} class="max-w-xl">
        <div class="mt-2 flex flex-col gap-3">
          <Row id="tenant-name" label={t.admin.tenants.name} hint={t.admin.tenants.freshHint}
            ><Input
              id="tenant-name"
              bind:value={name}
              disabled={!!pending}
              required
              maxlength={190}
              autocomplete="off"
            /></Row
          >
          <Notice {message} />
          <div>
            <Button type="submit" disabled={busy}
              >{pending ? t.lists.resume : t.lists.createCustomer}</Button
            >
          </div>
        </div>
      </Panel>
    </form>
  {/if}
</section>
