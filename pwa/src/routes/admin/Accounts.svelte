<script lang="ts">
  import { onMount } from 'svelte';
  import { confirmAction } from '$lib/confirm.svelte';
  import { t } from '$lib/i18n';
  import { adminApi, http } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import NewAccountPanel from './NewAccountPanel.svelte';
  import DataTable, { type Column } from '$lib/components/admin/DataTable.svelte';
  import RowMenu, { type RowMenuItem } from '$lib/components/admin/RowMenu.svelte';

  const c = t.accountsPackage;
  type Account = { id: string; username: string; active: boolean; mcpAllowed: boolean };
  let accounts = $state<Account[] | null>(null);
  let loadError = $state('');
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  let showCreate = $state(false);

  // Customers an account belongs to: only what the members endpoint of each customer reports.
  let customersOf = $state<Record<string, string[]>>({});
  let customersKnown = $state(false);
  async function loadCustomers(): Promise<void> {
    const found: Record<string, string[]> = {};
    let any = false;
    await Promise.all(
      session.tenants.slice(0, 25).map(async (tenant) => {
        const r = await adminApi.members(tenant.id);
        if (!r.ok) return;
        any = true;
        for (const m of r.data.items) (found[m.accountId] ??= []).push(tenant.name);
      }),
    );
    customersOf = found;
    customersKnown = any;
  }
  const columns = $derived<Column[]>([
    { id: 'name', header: c.colAccount },
    { id: 'status', header: c.colStatus },
    { id: 'mcp', header: c.colMcp, hideBelow: 'sm' },
    ...(customersKnown
      ? [{ id: 'customers', header: c.colCustomers, hideBelow: 'md' as const }]
      : []),
    { id: 'actions', header: c.colActions, align: 'right' as const, srOnlyHeader: true },
  ]);
  // The own account is a system administrator: it reaches every customer, not only the memberships.
  const customerText = (x: Account): string =>
    own(x) && session.me?.systemAdministrator
      ? c.allCustomers
      : (customersOf[x.id] ?? []).join(', ') || c.noCustomers;
  const own = (x: Account): boolean => x.id === session.me?.id;
  function menu(x: Account): RowMenuItem[] {
    return [
      {
        id: 'active',
        label: x.active ? c.lock : c.unlock,
        destructive: x.active,
        disabled: busy || (own(x) && x.active),
        onselect: () => void change(x, 'active'),
      },
      {
        id: 'mcp',
        label: x.mcpAllowed ? c.denyMcp : c.allowMcp,
        disabled: busy || (own(x) && x.mcpAllowed),
        onselect: () => void change(x, 'mcpAllowed'),
      },
    ];
  }

  async function load(): Promise<void> {
    loadError = '';
    const r = await http.request<{ items: Account[] }>('GET', '/accounts');
    if (r.ok) {
      accounts = r.data.items;
      void loadCustomers();
    } else if (!handleSessionError(r.error))
      loadError = r.error.status === 403 ? t.states.forbiddenTitle : describeError(r.error);
  }

  async function change(x: Account, field: 'active' | 'mcpAllowed'): Promise<void> {
    if (busy || (own(x) && x[field])) return;
    if (
      field === 'active' &&
      x.active &&
      !(await confirmAction({
        title: t.confirm.lockAccountTitle,
        description: t.confirm.lockAccountBody,
        confirmLabel: t.confirm.lockAccount,
        destructive: true,
      }))
    )
      return;
    if (
      field === 'mcpAllowed' &&
      x.mcpAllowed &&
      !(await confirmAction({
        title: t.confirm.denyMcpTitle,
        description: t.confirm.denyMcpBody,
        confirmLabel: t.confirm.denyMcp,
        destructive: true,
      }))
    )
      return;
    busy = true;
    message = ok = '';
    const r = await http.request<void>('PUT', `/accounts/${x.id}/status`, {
      body: { [field]: !x[field] },
    });
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error))
        message = r.error.status === 409 ? c.conflict : describeError(r.error);
      return;
    }
    ok = c.saved;
    await load();
  }

  onMount(() => void load());
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title={c.accountsPage} description={c.accountsIntro} compactActions>
    {#snippet actions()}
      {#if session.me?.systemAdministrator && !showCreate}
        <Button onclick={() => (showCreate = true)}>{c.createAccount}</Button>
      {/if}
    {/snippet}
  </PageHeader>
  {#if !session.me?.systemAdministrator}
    <ErrorState title={t.states.forbiddenTitle} message={t.states.forbiddenBody} />
  {:else if loadError}
    <ErrorState
      title={t.states.errorTitle}
      message={loadError}
      onretry={() => void load()}
      {busy}
    />
  {:else if accounts === null}
    <div aria-busy="true" class="flex flex-col gap-3">
      <span class="sr-only" role="status">{t.admin.loading}</span>
      <Skeleton class="h-16" /><Skeleton class="h-16" />
    </div>
  {:else}
    <Panel flush>
      {#if accounts.length === 0}
        <EmptyState icon="members" title={c.noAccounts} description={c.noAccountsHint}>
          {#snippet action()}
            {#if !showCreate}<Button onclick={() => (showCreate = true)}>{c.createAccount}</Button
              >{/if}
          {/snippet}
        </EmptyState>
      {:else}
        <DataTable label={c.accountsPage} {columns} rows={accounts} rowKey={(x) => x.id}>
          {#snippet cell(x, column)}
            {#if column.id === 'name'}
              <span class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{x.username}</span>
                {#if own(x)}<StatusChip tone="idle" label={t.admin.members.you} />{/if}
              </span>
            {:else if column.id === 'status'}
              <StatusChip tone={x.active ? 'ok' : 'warn'} label={x.active ? c.active : c.locked} />
            {:else if column.id === 'mcp'}
              <StatusChip
                tone={x.mcpAllowed ? 'ok' : 'idle'}
                label={x.mcpAllowed ? c.mcpOn : c.mcpOff}
              />
            {:else if column.id === 'customers'}
              <span class="text-muted-foreground">{customerText(x)}</span>
            {:else if column.id === 'actions'}
              <RowMenu label={c.menuLabel.replace('{name}', x.username)} items={menu(x)} />
            {/if}
          {/snippet}
        </DataTable>
      {/if}
    </Panel>
    {#if showCreate}
      <NewAccountPanel oncreated={() => void load()} onclose={() => (showCreate = false)} />
    {/if}
  {/if}
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</div>
