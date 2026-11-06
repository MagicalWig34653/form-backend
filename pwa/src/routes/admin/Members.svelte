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
      members.map((x) => [x.accountId, Object.fromEntries(x.permissions.map((p) => [p, true]))]),
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

<section class="flex flex-col gap-4">
  <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{m.title}</h1>
  <p class="text-muted-foreground max-w-prose text-sm">{m.intro}</p>
  {#if !loaded}
    <p>{t.admin.loading}</p>
  {:else}
    <ul class="flex flex-col gap-4">
      {#each members as x (x.accountId)}
        <li class="rounded-md border p-3">
          <h2 class="font-medium">
            {x.username}{x.accountId === session.me?.id ? ` ${m.you}` : ''}
          </h2>
          {#if x.inherited.length > 0}
            <p class="text-muted-foreground text-xs">
              {m.inherited.replace('{list}', x.inherited.join(', '))}
            </p>
          {/if}
          <fieldset
            class="mt-2 grid grid-cols-2 gap-1 text-sm"
            disabled={x.accountId === session.me?.id}
          >
            <legend class="sr-only">{x.username}</legend>
            {#each assignable as p (p)}
              <label class="flex items-center gap-2">
                <input type="checkbox" bind:checked={chosen[x.accountId]![p]} />
                <span>{p}</span>
              </label>
            {/each}
          </fieldset>
          {#if x.accountId !== session.me?.id}
            <div class="mt-2">
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
    <h2 class="text-lg font-medium">{c.accounts}</h2>
    <ul class="flex flex-col gap-3">
      {#each accounts as x (x.id)}
        <li class="rounded-md border p-3">
          <p>{x.username} · {x.active ? c.active : c.locked}</p>
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
</section>
