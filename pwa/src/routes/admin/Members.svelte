<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi, http } from '$lib/api';
  import type { Member } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import { Checkbox } from '$lib/components/ui/checkbox';

  let { tenant }: { tenant: string } = $props();
  const m = t.admin.members;
  const c = t.accountsPackage;
  type Account = { id: string; username: string; active: boolean; mcpAllowed: boolean };
  let accounts = $state<Account[]>([]);
  async function loadAccounts(): Promise<void> {
    if (!session.me?.systemAdministrator) return;
    const r = await http.request<{ items: Account[] }>('GET', '/accounts');
    if (r.ok) accounts = r.data.items;
    else if (!handleSessionError(r.error)) message = describeError(r.error);
  }
  async function changeAccount(x: Account, field: 'active' | 'mcpAllowed'): Promise<void> {
    if (busy || (field === 'active' && x.active && !confirm(c.confirmLock))) return;
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
    await loadAccounts();
    await load();
  }
  let members = $state<Member[]>([]);
  let assignable = $state<string[]>([]);
  let chosen = $state<Record<string, Record<string, boolean>>>({});
  let loaded = $state(false);
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);

  async function load(): Promise<void> {
    const r = await adminApi.members(tenant);
    if (!r.ok) {
      if (!handleSessionError(r.error)) message = describeError(r.error);
      loaded = true;
      return;
    }
    members = r.data.items;
    assignable = r.data.assignable;
    chosen = Object.fromEntries(
      members.map((x) => [
        x.accountId,
        Object.fromEntries(assignable.map((p) => [p, x.permissions.includes(p)])),
      ]),
    );
    loaded = true;
  }

  async function save(x: Member): Promise<void> {
    if (busy) return;
    busy = true;
    message = ok = '';
    const list = assignable.filter((p) => chosen[x.accountId]?.[p]);
    const r = await adminApi.setMemberPermissions(tenant, x.accountId, list);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error))
        message = r.error.status === 403 ? m.denied : describeError(r.error);
      return;
    }
    ok = m.saved;
    await load();
  }

  onMount(() => {
    void load();
    void loadAccounts();
  });
</script>

<div class="flex w-full max-w-[820px] flex-col gap-6">
  <PageHeader title={m.title} description={m.intro} />
  {#if !loaded}
    <div aria-busy="true" class="flex flex-col gap-3">
      <span class="sr-only" role="status">{t.admin.loading}</span>
      <Skeleton class="h-32" /><Skeleton class="h-32" />
    </div>
  {:else}
    <ul class="flex flex-col gap-4">
      {#each members as x (x.accountId)}
        <li class="bg-card ring-1 ring-foreground/10 rounded-xl px-5 py-4">
          <h2 class="font-semibold">
            {x.username}{x.accountId === session.me?.id ? ` ${m.you}` : ''}
          </h2>
          {#if x.inherited.length > 0}
            <p class="text-muted-foreground text-xs">
              {m.inherited.replace('{list}', x.inherited.join(', '))}
            </p>
          {/if}
          <fieldset
            class="mt-3 grid gap-x-4 gap-y-1 text-sm sm:grid-cols-2"
            disabled={x.accountId === session.me?.id}
          >
            <legend class="sr-only">{x.username}</legend>
            {#each assignable as p (p)}
              <label class="flex min-h-8 items-center gap-2">
                <Checkbox bind:checked={chosen[x.accountId]![p]} />
                <span>{p}</span>
              </label>
            {/each}
          </fieldset>
          {#if x.accountId !== session.me?.id}
            <div class="mt-3">
              <Button type="button" variant="outline" disabled={busy} onclick={() => void save(x)}
                >{m.save}</Button
              >
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
  {#if session.me?.systemAdministrator}
    <h2 class="text-[17px] font-semibold">{c.accounts}</h2>
    <ul class="flex flex-col gap-3">
      {#each accounts as x (x.id)}
        <li class="bg-card ring-1 ring-foreground/10 rounded-xl px-5 py-4">
          <p class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{x.username}</span>
            <StatusChip tone={x.active ? 'ok' : 'idle'} label={x.active ? c.active : c.locked} />
          </p>
          <div class="mt-2 flex flex-wrap gap-2">
            <Button
              variant="outline"
              disabled={busy}
              onclick={() => void changeAccount(x, 'active')}>{x.active ? c.lock : c.unlock}</Button
            >
            <Button
              variant="outline"
              disabled={busy}
              onclick={() => void changeAccount(x, 'mcpAllowed')}
              >{x.mcpAllowed ? c.denyMcp : c.allowMcp}</Button
            >
          </div>
        </li>
      {/each}
    </ul>
  {/if}
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</div>
