<script lang="ts">
  import AccessStatus from './AccessStatus.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { onMount, onDestroy, untrack } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi, http } from '$lib/api';
  import { session } from '$lib/session.svelte';
  import { Table } from '$lib/components/ui/table';
  import { Select } from '$lib/components/ui/select';
  import type { FormListItem } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import NeedHint from '$lib/components/admin/NeedHint.svelte';
  import { Card } from '$lib/components/ui/card';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
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
    } else if (!handleSessionError(r.error)) {
      loadError =
        r.error.status === 403
          ? t.lists.forbidden
          : r.error.status === 404
            ? t.lists.notFound
            : t.lists.failed;
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
    router.navigate(formPath(tenant, r.data.id));
  }

  onMount(() => void load());
  onDestroy(() => {
    loader.cancel();
    controller?.abort();
    clearTimeout(timer);
  });
</script>

<section class="flex min-w-0 flex-col gap-4">
  <AccessStatus />
  <PageHeader
    title={t.admin.forms.title}
    description={`${session.tenants.find((c) => c.id === tenant)?.name ?? ''} · ${t.lists.formsIntro}`}
  >
    {#snippet actions()}
      {#if canCreate}<Button
          onclick={() => {
            showCreate = true;
          }}>{t.lists.createForm}</Button
        >{/if}
    {/snippet}
  </PageHeader>
  <NeedHint
    accepts={['entries', 'statistics']}
    onshown={() => setTimeout(() => listEl?.focus(), 80)}
  />
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
  <Card class="gap-0 py-0">
    <div class="grid gap-3 border-b p-4 sm:grid-cols-2">
      <Row id="forms-search" label={t.lists.searchForms}
        ><Input id="forms-search" type="search" bind:value={query} /></Row
      >
      <Row id="forms-status" label={t.lists.status}
        ><Select id="forms-status" bind:value={status}>
          <option value="">{t.lists.all}</option><option value="active">{t.lists.active}</option
          ><option value="inactive">{t.lists.inactive}</option><option value="unpublished"
            >{t.lists.unpublished}</option
          >
        </Select></Row
      >
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
    <div bind:this={listEl} tabindex="-1" aria-busy={loading} class="min-h-48 outline-none">
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
        <Table
          ><caption class="sr-only">{t.admin.forms.title}</caption>
          <thead class="bg-muted/50 text-muted-foreground text-sm"
            ><tr
              >{#each [t.lists.name, t.lists.publication, t.overview.activity, t.lists.tasks] as heading (heading)}<th
                  scope="col"
                  class="h-10 !py-0 text-left whitespace-nowrap">{heading}</th
                >{/each}</tr
            ></thead
          >
          <tbody
            >{#each visible as f (f.id)}<tr class="hover:bg-muted/50 transition-colors">
                <th scope="row" class="text-left"
                  ><a
                    class="font-medium underline underline-offset-4"
                    href={formPath(tenant, f.id)}
                    onclick={(e) => {
                      e.preventDefault();
                      router.navigate(formPath(tenant, f.id));
                    }}>{f.name}</a
                  >
                  <div class="mt-1">
                    <StatusChip
                      tone={!f.currentReleaseId ? 'info' : f.active ? 'ok' : 'idle'}
                      label={f.active ? t.lists.active : t.lists.inactive}
                    />
                  </div></th
                >
                <td>{f.currentReleaseId ? t.lists.published : t.lists.unpublished}</td><td>
                  {#if loader.snapshots.get(f.id)?.statsStatus === 'loading' || !loader.snapshots.has(f.id)}
                    <Skeleton class="h-6 w-24" />
                  {:else if rowSeries(f.id)}
                    {@const series = rowSeries(f.id) ?? []}
                    <div class="flex items-center gap-2">
                      <Sparkline
                        class="max-h-8 w-24"
                        values={series}
                        label={t.overview.sparkLabel
                          .replace('{metric}', t.overview.kpiSubmits)
                          .replace(
                            '{values}',
                            series.map((v) => (v === null ? '–' : v)).join(', '),
                          )}
                      /><span class="text-sm tabular-nums">{total(series) ?? '–'}</span>
                    </div>
                  {:else}<span class="text-muted-foreground">{t.overview.activityNone}</span>{/if}
                </td>
                <td
                  ><a
                    class="underline underline-offset-4"
                    aria-label={`${t.lists.openOverview}: ${f.name}`}
                    href={formPath(tenant, f.id)}
                    onclick={(e) => {
                      e.preventDefault();
                      router.navigate(formPath(tenant, f.id));
                    }}>{t.lists.openOverview}</a
                  ></td
                >
              </tr>{/each}</tbody
          >
        </Table>
      {/if}
    </div>
  </Card>
  <p class="text-muted-foreground text-sm">{t.lists.metadataHint}</p>
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
