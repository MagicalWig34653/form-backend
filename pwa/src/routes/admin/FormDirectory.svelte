<script lang="ts">
  import { untrack } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { FORM_DIRECTORY_PATH, formPath } from '$lib/routes';
  import { session } from '$lib/session.svelte';
  import { formLists } from '$lib/formLists.svelte';
  import { Button } from '$lib/components/ui/button';
  import SearchField from '$lib/components/admin/SearchField.svelte';
  import { formStatus } from '$lib/admin/formStatus';
  import DataTable, { type Column } from '$lib/components/admin/DataTable.svelte';
  import FilterBar from '$lib/components/admin/FilterBar.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  const d = t.directory;
  let query = $state('');

  // The customer filter lives in the URL (?kunde=<id>) so it can be shared and removed again.
  const customerFilter = $derived.by(() => {
    const id = new URLSearchParams(router.search).get('kunde');
    return id && session.tenants.some((x) => x.id === id) ? id : null;
  });
  const customers = $derived(
    session.tenants.filter((x) => (customerFilter ? x.id === customerFilter : true)),
  );
  const filterName = $derived(session.tenants.find((x) => x.id === customerFilter)?.name ?? '');

  // Reads only the customer ids; loading writes the list states, which must not retrigger this effect.
  $effect(() => {
    const ids = customers.map((x) => x.id);
    untrack(() => void formLists.ensure(ids));
  });

  interface Line {
    key: string;
    tenant: string;
    tenantName: string;
    form: string;
    name: string;
    active: boolean;
    published: boolean;
  }
  const states = $derived(
    customers.map((x) => ({ customer: x, state: formLists.states.get(x.id) })),
  );
  const lines = $derived.by<Line[]>(() => {
    const out: Line[] = [];
    for (const { customer, state } of states)
      for (const f of state?.items ?? [])
        out.push({
          key: `${customer.id}/${f.id}`,
          tenant: customer.id,
          tenantName: customer.name,
          form: f.id,
          name: f.name,
          active: f.active,
          published: f.currentReleaseId !== null,
        });
    return out;
  });
  const needle = $derived(query.trim().toLocaleLowerCase('de'));
  const visible = $derived(
    lines.filter(
      (l) => !needle || `${l.name} ${l.tenantName}`.toLocaleLowerCase('de').includes(needle),
    ),
  );
  const loading = $derived(states.some((s) => !s.state || s.state.status === 'loading'));
  const failed = $derived(states.filter((s) => s.state?.status === 'error'));
  const truncated = $derived(states.filter((s) => s.state?.more));
  const filters = $derived((customerFilter ? 1 : 0) + (needle ? 1 : 0));
  const columns: Column[] = [
    { id: 'name', header: d.form },
    { id: 'customer', header: d.customer, hideBelow: 'sm' },
    { id: 'status', header: d.status },
  ];
  const status = (l: Line) => formStatus(l.published, l.active);
  const reset = (): void => {
    query = '';
    if (customerFilter) router.navigate(FORM_DIRECTORY_PATH);
  };
</script>

<section class="flex min-w-0 flex-col gap-5">
  <PageHeader title={d.title} description={d.intro} />
  <FilterBar collapsible={false} activeCount={filters} onreset={reset}>
    <SearchField
      id="directory-search"
      label={d.search}
      placeholder={d.searchPlaceholder}
      bind:value={query}
    />
    {#snippet trailing()}
      {#if customerFilter}
        <Button
          type="button"
          variant="outline"
          aria-label={d.removeFilter.replace('{name}', filterName)}
          onclick={() => router.navigate(FORM_DIRECTORY_PATH)}
          >{d.customerFilter.replace('{name}', filterName)}<NavIcon name="x" size={14} /></Button
        >
      {/if}
      {#if !loading}<span
          class="text-muted-foreground flex min-h-10 items-center text-sm tabular-nums"
          >{visible.length === 1
            ? d.countOne
            : d.count.replace('{n}', String(visible.length))}</span
        >{/if}
    {/snippet}
  </FilterBar>
  {#each failed as s (s.customer.id)}
    <Banner tone="danger">
      {d.failed.replace('{name}', s.customer.name)}
      {#snippet action()}
        <Button variant="outline" onclick={() => void formLists.load(s.customer.id, true)}
          >{t.admin.retry}</Button
        >
      {/snippet}
    </Banner>
  {/each}
  <Panel flush>
    <div aria-busy={loading}>
      {#if loading && lines.length === 0}
        <div class="flex flex-col gap-3 p-4" aria-hidden="true">
          {#each [1, 2, 3] as n (n)}<Skeleton class="h-11 rounded-md" />{/each}
        </div>
        <p role="status" class="sr-only">{t.admin.loading}</p>
      {:else if lines.length === 0}
        <EmptyState icon="forms" title={d.noForms} />
      {:else if visible.length === 0}
        <EmptyState icon="search" title={d.noMatches}>
          {#snippet action()}
            <Button variant="outline" onclick={reset}>{d.resetFilters}</Button>
          {/snippet}
        </EmptyState>
      {:else}
        <DataTable
          label={d.title}
          {columns}
          rows={visible}
          rowKey={(l) => l.key}
          rowHref={(l) => formPath(l.tenant, l.form)}
        >
          {#snippet cell(l, column)}
            {#if column.id === 'name'}
              <a
                class="min-w-0 font-medium break-words underline-offset-4 hover:underline"
                href={formPath(l.tenant, l.form)}
                onclick={(e) => {
                  if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
                  e.preventDefault();
                  router.navigate(formPath(l.tenant, l.form));
                }}>{l.name}</a
              >
            {:else if column.id === 'customer'}
              <span class="text-muted-foreground">{l.tenantName}</span>
            {:else}
              {@const s = status(l)}
              <StatusChip tone={s.tone} label={s.label} />
            {/if}
          {/snippet}
        </DataTable>
      {/if}
    </div>
  </Panel>
  {#each truncated as s (s.customer.id)}
    <p class="text-muted-foreground text-sm">{d.more.replace('{name}', s.customer.name)}</p>
  {/each}
</section>
