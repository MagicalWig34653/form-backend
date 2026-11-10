<script lang="ts">
  import { onMount } from 'svelte';
  import { confirmAction } from '$lib/confirm.svelte';
  import { t } from '$lib/i18n';
  import { http } from '$lib/api';
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

  const c = t.accountsPackage;
  type Account = { id: string; username: string; active: boolean; mcpAllowed: boolean };
  let accounts = $state<Account[] | null>(null);
  let loadError = $state('');
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  let showCreate = $state(false);

  async function load(): Promise<void> {
    loadError = '';
    const r = await http.request<{ items: Account[] }>('GET', '/accounts');
    if (r.ok) accounts = r.data.items;
    else if (!handleSessionError(r.error))
      loadError = r.error.status === 403 ? t.states.forbiddenTitle : describeError(r.error);
  }

  async function change(x: Account, field: 'active' | 'mcpAllowed'): Promise<void> {
    if (busy) return;
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
        <ul class="divide-border m-0 flex list-none flex-col divide-y p-0">
          {#each accounts as x (x.id)}
            <li class="flex flex-wrap items-center justify-between gap-x-4 gap-y-3 px-5 py-4">
              <span class="flex min-w-0 flex-wrap items-center gap-2">
                <span class="font-medium">{x.username}</span>
                <StatusChip
                  tone={x.active ? 'ok' : 'warn'}
                  label={x.active ? c.active : c.locked}
                />
                {#if !x.mcpAllowed}<StatusChip tone="idle" label={c.mcpOff} />{/if}
              </span>
              <span class="flex flex-wrap gap-2">
                <Button variant="outline" disabled={busy} onclick={() => void change(x, 'active')}
                  >{x.active ? c.lock : c.unlock}</Button
                >
                <Button
                  variant="outline"
                  disabled={busy}
                  onclick={() => void change(x, 'mcpAllowed')}
                  >{x.mcpAllowed ? c.denyMcp : c.allowMcp}</Button
                >
              </span>
            </li>
          {/each}
        </ul>
      {/if}
    </Panel>
    {#if showCreate}
      <NewAccountPanel oncreated={() => void load()} onclose={() => (showCreate = false)} />
    {/if}
  {/if}
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</div>
