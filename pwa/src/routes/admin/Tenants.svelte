<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import type { Tenant } from '$lib/api/admin';
  import { Table } from '$lib/components/ui/table';
  import { Select } from '$lib/components/ui/select';
  import AccessStatus from './AccessStatus.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { tenantPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';

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

<section class="flex min-w-0 flex-col gap-4">
  <AccessStatus />
  <div class="flex flex-wrap items-center justify-between gap-3">
    <div>
      <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{t.admin.tenants.title}</h1>
      <p class="text-muted-foreground text-sm">{t.lists.intro}</p>
    </div>
    {#if session.me?.systemAdministrator}<Button
        onclick={() => {
          showCreate = true;
        }}>{t.lists.createCustomer}</Button
      >{/if}
  </div>
  <div class="grid gap-3 sm:grid-cols-2">
    <Row id="customer-search" label={t.lists.searchCustomers}
      ><Input id="customer-search" type="search" bind:value={query} /></Row
    >
    <Row id="customer-scope" label={t.lists.status}
      ><Select id="customer-scope"><option>{t.lists.all}</option></Select></Row
    >
  </div>
  <div role="status" class="text-muted-foreground text-sm">
    {loading ? (slow ? t.lists.slow : t.admin.loading) : ''}
  </div>
  {#if loadError}<p role="alert">{loadError}</p>
    <div><Button variant="outline" onclick={() => void load()}>{t.lists.retry}</Button></div>{/if}
  <div aria-busy={loading} class="bg-card border-border min-h-48 rounded-xl border">
    {#if loading && items === null}<div class="flex flex-col gap-4 p-4" aria-hidden="true">
        {#each [1, 2, 3] as n (n)}<div class="bg-muted h-10 rounded"></div>{/each}
      </div>
    {:else if items !== null && items.length === 0}<p class="p-6">
        {session.me?.systemAdministrator ? t.lists.noCustomers : t.lists.noAccess}
      </p>
    {:else if items !== null && visible.length === 0}<div class="p-6">
        <p>{t.lists.noCustomerMatches}</p>
        <Button
          variant="outline"
          onclick={() => {
            query = '';
          }}>{t.lists.reset}</Button
        >
      </div>
    {:else if items !== null}<Table
        ><caption class="sr-only">{t.admin.tenants.title}</caption><thead
          ><tr
            >{#each [t.lists.name, t.lists.forms, t.lists.setup, t.lists.action] as heading (heading)}<th
                scope="col">{heading}</th
              >{/each}</tr
          ></thead
        >
        <tbody
          >{#each visible as c (c.id)}<tr
              ><th scope="row" class="font-medium">{c.name}</th><td>{t.lists.unknown}</td><td
                >{pending?.id === c.id
                  ? busy
                    ? t.lists.preparing
                    : incomplete
                      ? t.lists.incomplete
                      : t.lists.unknown
                  : t.lists.unknown}</td
              ><td
                ><a
                  class="underline underline-offset-4"
                  aria-label={`${t.lists.open}: ${c.name}`}
                  href={tenantPath(c.id)}
                  onclick={(e) => {
                    e.preventDefault();
                    router.navigate(tenantPath(c.id));
                  }}>{t.lists.open}</a
                ></td
              ></tr
            >{/each}</tbody
        >
      </Table>{/if}
  </div>
  <p class="text-muted-foreground text-sm">{t.lists.countHint}</p>
  {#if session.me?.systemAdministrator && showCreate}
    <form
      onsubmit={(e) => void create(e)}
      class="bg-card border-border flex max-w-xl flex-col gap-3 rounded-xl border p-5"
      aria-busy={busy}
    >
      <h2 class="text-lg font-medium">{t.lists.createCustomer}</h2>
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
    </form>
  {/if}
</section>
