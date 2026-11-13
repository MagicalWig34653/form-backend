<script lang="ts">
  import AccessStatus from './AccessStatus.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { onMount, onDestroy, untrack } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi, http } from '$lib/api';
  import { session } from '$lib/session.svelte';
  import DataTable, { type Column } from '$lib/components/admin/DataTable.svelte';
  import SearchField from '$lib/components/admin/SearchField.svelte';
  import { formStatus } from '$lib/admin/formStatus';
  import { Select } from '$lib/components/ui/select';
  import type { FormListItem } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { describeError, loadFailureText } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import NeedHint from '$lib/components/admin/NeedHint.svelte';
  import { Card } from '$lib/components/ui/card';
  import Notice from '$lib/components/admin/Notice.svelte';
  import CustomerHeader from '$lib/components/admin/CustomerHeader.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { formLists } from '$lib/formLists.svelte';
  import { OverviewLoader } from '$lib/stats/loader.svelte';
  import { dailySeries, total } from '$lib/stats/series';
  import TenantOverview from './overview/TenantOverview.svelte';
  import KpiTile from './overview/KpiTile.svelte';
  import Sparkline from './overview/Sparkline.svelte';

  let { tenant }: { tenant: string } = $props();

  let listEl = $state<HTMLElement | undefined>();
  let items = $state<FormListItem[] | null>(null);
  let query = $state('');
  let status = $state('');
  let loading = $state(true);
  let slow = $state(false);
  let loadError = $state('');
  let nextCursor = $state<string | null>(null);
  let showCreate = $state(false);
  let controller: AbortController | undefined;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const canCreate = $derived(
    session.tenants.find((t) => t.id === tenant)?.permissions.includes('form.create') ?? false,
  );
  const visible = $derived(
    (items ?? []).filter(
      (f) =>
        f.name.toLocaleLowerCase('de').includes(query.trim().toLocaleLowerCase('de')) &&
        (!status ||
          (status === 'unpublished'
            ? !f.currentReleaseId
            : status === 'active'
              ? f.active
              : !f.active)),
    ),
  );
  const columns: Column[] = [
    { id: 'name', header: t.lists.name },
    { id: 'status', header: t.lists.status },
    { id: 'activity', header: t.overview.activity, hideBelow: 'sm' },
  ];
  const loader = new OverviewLoader(adminApi, handleSessionError);
  // (Re)load the per-form figures whenever the list of forms changes; metadata only, nothing is decrypted.
  $effect(() => {
    const list = items;
    if (list && list.length > 0)
      untrack(() => {
        void loader.load(tenant, list);
      });
  });
  const rowSeries = (id: string): (number | null)[] | null => {
    const snap = loader.snapshots.get(id);
    return snap?.stats ? dailySeries(snap.stats, 'submits') : null;
  };
  let name = $state('');
  let busy = $state(false);
  let message = $state('');

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
    const r = nextCursor
      ? await http.request<{ items: FormListItem[]; nextCursor: string | null }>(
          'GET',
          `/tenants/${encodeURIComponent(tenant)}/forms?limit=100&cursor=${encodeURIComponent(nextCursor)}`,
          { signal: request.signal },
        )
      : await adminApi.forms(tenant, request.signal);
    if (request.signal.aborted) return;
    clearTimeout(timer);
    loading = false;
    if (r.ok) {
      items = nextCursor
        ? [...(items ?? []), ...r.data.items.filter((f) => !items?.some((old) => old.id === f.id))]
        : r.data.items;
      nextCursor = r.data.nextCursor;
      formLists.set(tenant, items ?? [], nextCursor !== null);
    } else if (!handleSessionError(r.error)) {
      loadError =
        r.error.status === 403
          ? t.lists.forbidden
          : r.error.status === 404
            ? t.lists.notFound
            : loadFailureText(r.error, t.lists.failed);
    }
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy || !canCreate || !name.trim()) return;
    busy = true;
    message = '';
    try {
      await accessAutomation.ensureCustomer(tenant);
    } catch (error) {
      message = (error as Error).message;
      busy = false;
      return;
    }
    const r = await adminApi.createForm(tenant, name.trim());
    busy = false;
    if (!r.ok) {
      if (!handleSessionError(r.error)) message = describeError(r.error);
      return;
    }
    formLists.invalidate(tenant);
    if (!leftList) router.navigate(formPath(tenant, r.data.id)); // not after the user went elsewhere meanwhile
  }

  let leftList = false;
  onMount(() => void load());
  onDestroy(() => {
    leftList = true;
    loader.cancel();
    controller?.abort();
    clearTimeout(timer);
  });
</script>

<section class="flex min-w-0 flex-col gap-4">
  <CustomerHeader {tenant} current="forms">
    {#snippet actions()}
      {#if canCreate}<Button
          onclick={() => {
            showCreate = true;
          }}>{t.lists.createForm}</Button
        >{/if}
    {/snippet}
  </CustomerHeader>
  <AccessStatus />
  <NeedHint
    accepts={['entries', 'statistics']}
    onshown={() => setTimeout(() => listEl?.focus(), 80)}
  />
  <Card class="gap-0 py-0">
    <div class="flex flex-wrap gap-3 border-b p-4">
      <SearchField
        id="forms-search"
        label={t.lists.searchForms}
        placeholder={t.lists.searchFormsPlaceholder}
        bind:value={query}
      />
      <Select
        id="forms-status"
        aria-label={t.lists.status}
        bind:value={status}
        class="w-full sm:w-48"
      >
        <option value="">{t.lists.allStatus}</option><option value="active">{t.lists.active}</option
        ><option value="inactive">{t.lists.inactive}</option><option value="unpublished"
          >{t.status.draft}</option
        >
      </Select>
    </div>
    <div role="status" class="text-muted-foreground px-4 text-sm empty:hidden">
      {loading ? (slow ? t.lists.slow : t.admin.loading) : ''}
    </div>
    {#if loadError}<div class="p-4">
        <Banner tone="danger">
          {loadError}
          {#snippet action()}
            <Button variant="outline" onclick={() => void load()}>{t.lists.retry}</Button>
          {/snippet}
        </Banner>
      </div>{/if}
    <div
      bind:this={listEl}
      tabindex="-1"
      aria-busy={loading}
      class={`outline-none ${loading && items === null ? 'min-h-48' : ''}`}
    >
      {#if items === null && loading}
        <div class="flex flex-col gap-4 p-4" aria-hidden="true">
          {#each [1, 2, 3] as n (n)}<div class="bg-muted h-10 rounded"></div>{/each}
        </div>
      {:else if items !== null && items.length === 0}
        <EmptyState icon="forms" title={t.admin.forms.none} />
      {:else if items !== null && visible.length === 0}
        <EmptyState icon="search" title={t.lists.noMatches}>
          {#snippet action()}
            <Button
              variant="outline"
              onclick={() => {
                query = '';
                status = '';
              }}>{t.lists.reset}</Button
            >
          {/snippet}
        </EmptyState>
      {:else if items !== null}
        <DataTable
          label={t.admin.forms.title}
          {columns}
          rows={visible}
          rowKey={(f) => f.id}
          rowHref={(f) => formPath(tenant, f.id)}
        >
          {#snippet cell(f, column)}
            {#if column.id === 'name'}
              <a
                class="font-medium underline-offset-4 hover:underline"
                href={formPath(tenant, f.id)}
                onclick={(e) => {
                  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
                  e.preventDefault();
                  router.navigate(formPath(tenant, f.id));
                }}>{f.name}</a
              >
            {:else if column.id === 'status'}
              {@const st = formStatus(!!f.currentReleaseId, f.active)}
              <StatusChip tone={st.tone} label={st.label} />
            {:else if loader.snapshots.get(f.id)?.statsStatus === 'loading' || !loader.snapshots.has(f.id)}
              <Skeleton class="h-5 w-24" />
            {:else if rowSeries(f.id)}
              {@const series = rowSeries(f.id) ?? []}
              <div class="flex items-center gap-2">
                <Sparkline
                  class="max-h-8 w-24 max-sm:hidden"
                  values={series}
                  label={t.overview.sparkLabel
                    .replace('{metric}', t.overview.kpiSubmits)
                    .replace('{values}', series.map((v) => (v === null ? '–' : v)).join(', '))}
                /><span class="text-sm tabular-nums">{total(series) ?? '–'}</span><span
                  class="text-muted-foreground text-xs sm:hidden">{t.overview.activityUnit}</span
                >
              </div>
            {:else}<span class="text-muted-foreground">{t.overview.activityNone}</span>{/if}
          {/snippet}
        </DataTable>
      {/if}
    </div>
  </Card>
  {#if items === null && loading}
    <div class="tile-grid" aria-busy="true">
      {#each [0, 1, 2, 3] as n (n)}<div data-w="3">
          <KpiTile label={t.overview.kpiSubmits} status="loading" index={n} />
        </div>{/each}
    </div>
  {:else if items !== null && items.length > 0}
    <TenantOverview
      {tenant}
      forms={items}
      {loader}
      locked={!keyring.unlocked}
      moreForms={nextCursor !== null}
      onreload={() => void loader.load(tenant, items ?? [])}
    />
  {/if}
  {#if nextCursor}<p class="text-muted-foreground text-sm">{t.lists.partial}</p>
    <div>
      <Button variant="outline" disabled={loading} onclick={() => void load()}
        >{t.lists.more}</Button
      >
    </div>{/if}
  {#if canCreate && showCreate}
    <form
      onsubmit={(e) => void create(e)}
      class="bg-card ring-foreground/10 flex max-w-xl flex-col gap-3 rounded-xl p-5 ring-1"
      aria-busy={busy}
    >
      <h2 class="text-lg font-medium">{t.lists.createForm}</h2>
      <p class="text-muted-foreground text-sm">{t.lists.guide}</p>
      <Row id="form-name" label={t.admin.forms.name}
        ><Input id="form-name" bind:value={name} required maxlength={190} autocomplete="off" /></Row
      >
      <Notice {message} />
      <div><Button type="submit" disabled={busy}>{t.lists.createForm}</Button></div>
    </form>
  {/if}
</section>
