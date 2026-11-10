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
  import CustomerHeader from '$lib/components/admin/CustomerHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import { rightHint, rightLabel, rightsText } from '$lib/admin/rights';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import { Checkbox } from '$lib/components/ui/checkbox';

  let { tenant }: { tenant: string } = $props();
  const m = t.admin.members;
  type Account = { id: string; username: string; active: boolean; mcpAllowed: boolean };
  let accounts = $state<Account[]>([]);
  async function loadAccounts(): Promise<void> {
    if (!session.me?.systemAdministrator) return;
    const r = await http.request<{ items: Account[] }>('GET', '/accounts');
    if (r.ok) accounts = r.data.items;
    else if (!handleSessionError(r.error)) message = describeError(r.error);
  }
  const candidates = $derived(
    accounts.filter((x) => x.active && !members.some((member) => member.accountId === x.id)),
  );
  let addId = $state('');
  async function addMember(): Promise<void> {
    if (busy || !addId) return;
    busy = true;
    message = ok = '';
    const r = await adminApi.setMemberPermissions(tenant, addId, ['form.read']);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error))
        message = r.error.status === 403 ? m.denied : describeError(r.error);
      return;
    }
    ok = m.added;
    addId = '';
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

<div class="flex w-full min-w-0 flex-col gap-6">
  <CustomerHeader {tenant} current="members" />
  <Panel title={m.title} description={m.intro}>
    {#snippet actions()}
      {#if candidates.length > 0}
        <div class="flex flex-wrap items-center gap-2">
          <Select id="member-add" aria-label={m.addPick} bind:value={addId} class="w-56">
            <option value="">{m.addPick}</option>
            {#each candidates as x (x.id)}<option value={x.id}>{x.username}</option>{/each}
          </Select>
          <Button type="button" disabled={busy || !addId} onclick={() => void addMember()}
            >{m.add}</Button
          >
        </div>
      {/if}
    {/snippet}
    {#if !loaded}
      <div aria-busy="true" class="flex flex-col gap-3">
        <span class="sr-only" role="status">{t.admin.loading}</span>
        <Skeleton class="h-24" /><Skeleton class="h-24" />
      </div>
    {:else if members.length === 0}
      <EmptyState icon="customers" title={m.none} description={m.noneHint}>
        {#snippet action()}
          {#if session.me?.systemAdministrator}
            <Button variant="outline" onclick={() => router.navigate('/accounts')}
              >{m.toAccounts}</Button
            >
          {/if}
        {/snippet}
      </EmptyState>
    {:else}
      <ul class="divide-border -my-1 flex list-none flex-col divide-y p-0">
        {#each members as x (x.accountId)}
          {@const own = x.accountId === session.me?.id}
          {@const changed = assignable.some(
            (p) => !!chosen[x.accountId]?.[p] !== x.permissions.includes(p),
          )}
          <li class="py-4">
            <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
              <h3 class="m-0 text-base font-semibold">{x.username}</h3>
              {#if own}<StatusChip tone="idle" label={m.you} />{/if}
              {#if x.inherited.length > 0}
                <span class="text-muted-foreground text-xs"
                  >{m.inherited.replace('{list}', rightsText(x.inherited))}</span
                >
              {/if}
            </div>
            <fieldset
              class="mt-3 grid min-w-0 gap-x-6 gap-y-3 border-0 p-0 sm:grid-cols-2"
              disabled={own}
            >
              <legend class="sr-only">{x.username}</legend>
              {#each assignable as p (p)}
                <label class="flex min-h-10 items-start gap-3 text-sm">
                  <Checkbox bind:checked={chosen[x.accountId]![p]} class="mt-0.5" />
                  <span class="min-w-0">
                    <span class="block font-medium">{rightLabel(p)}</span>
                    {#if rightHint(p)}<span class="text-muted-foreground block text-xs leading-4"
                        >{rightHint(p)}</span
                      >{/if}
                  </span>
                </label>
              {/each}
            </fieldset>
            {#if own}
              <p class="text-muted-foreground mt-2 mb-0 text-xs">{m.ownLocked}</p>
            {:else}
              <div class="mt-3">
                <Button
                  type="button"
                  variant="outline"
                  disabled={busy || !changed}
                  onclick={() => void save(x)}>{m.save}</Button
                >
              </div>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </Panel>
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</div>
