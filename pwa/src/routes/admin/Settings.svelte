<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import FormSection from '$lib/components/admin/FormSection.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip, { type Tone } from '$lib/components/admin/StatusChip.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import SaveBar from '$lib/components/admin/SaveBar.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { formatClock, stamped } from '$lib/format';
  import SearchField from '$lib/components/admin/SearchField.svelte';
  interface Item {
    definition: {
      key: string;
      group: string;
      type: string;
      envName: string;
      minimum?: number;
      maximum?: number;
      restartRequired: boolean;
      sensitive: boolean;
    };
    value?: string;
    source: string;
    locked: boolean;
  }
  interface Snapshot {
    revision: string;
    items: Item[];
  }
  const text = t.admin.settings;
  const ui = t.formKit.settings;
  type Source = keyof typeof ui.sources;
  const tones: Record<Source, Tone> = { env: 'info', db: 'ok', default: 'idle' };
  let query = $state('');
  let sourceFilter = $state('');
  const sourceOf = (item: Item): Source =>
    item.source in ui.sources ? (item.source as Source) : 'default';
  const knownGroups = [
    t.abuse.title,
    'Mail-Netze',
    'Limits',
    'Aufbewahrungsstandard',
    'Speicher',
    'Webhook-Limits',
    'MCP-Token-Ratelimit',
    'Hosts',
    'Einrichtung',
    'Umstieg',
  ];
  let snapshot = $state<Snapshot>();
  let values = $state<Record<string, string>>({});
  let busy = $state(false);
  let error = $state('');
  let notice = $state('');
  let loadedAt = $state<Date | null>(null);
  const visible = $derived(
    (snapshot?.items ?? []).filter((x) => {
      const q = query.trim().toLowerCase();
      return (
        (!sourceFilter || sourceOf(x) === sourceFilter) &&
        (!q ||
          x.definition.key.toLowerCase().includes(q) ||
          x.definition.envName.toLowerCase().includes(q))
      );
    }),
  );
  const dirty = $derived(
    snapshot
      ? snapshot.items.filter((x) => !x.locked && values[x.definition.key] !== (x.value ?? ''))
          .length
      : 0,
  );
  // Known groups come first in their usual order; groups the server adds follow alphabetically.
  const groups = $derived.by(() => {
    const present = new Set((snapshot?.items ?? []).map((x) => x.definition.group));
    return [
      ...knownGroups.filter((g) => present.has(g)),
      ...[...present]
        .filter((g) => !knownGroups.includes(g))
        .sort((a, b) => a.localeCompare(b, 'de')),
    ];
  });
  const groupCounts = $derived(
    groups
      .map((g) => ({ g, n: visible.filter((x) => x.definition.group === g).length }))
      .filter((x) => x.n > 0),
  );
  const emptyGroups = $derived(knownGroups.filter((g) => !groups.includes(g)));
  function resetFilters(): void {
    query = '';
    sourceFilter = '';
  }
  const slug = (g: string) => 'grp-' + g.toLowerCase().replace(/[^a-z0-9]+/g, '-');
  async function failure(e: Parameters<typeof describeError>[0]) {
    if (e.status === 409) error = text.conflict;
    else if (needsFreshLogin(e)) await reauthenticate('/settings');
    else if (!handleSessionError(e)) error = describeError(e);
  }
  function accept(data: Snapshot) {
    snapshot = data;
    loadedAt = new Date();
    values = Object.fromEntries(data.items.map((x) => [x.definition.key, x.value ?? '']));
  }
  async function load() {
    busy = true;
    error = '';
    notice = '';
    const r = await http.request<Snapshot>('GET', '/settings');
    if (r.ok) accept(r.data);
    else await failure(r.error);
    busy = false;
  }
  async function save(e: SubmitEvent) {
    e.preventDefault();
    if (!snapshot || busy) return;
    const changed = snapshot.items.filter(
      (x) => !x.locked && values[x.definition.key] !== (x.value ?? ''),
    );
    if (!changed.length) return;
    busy = true;
    error = '';
    notice = '';
    const r = await http.request<Snapshot>('PUT', '/settings', {
      body: {
        revision: snapshot.revision,
        values: Object.fromEntries(
          changed.map((x) => [x.definition.key, values[x.definition.key]]),
        ),
      },
    });
    if (r.ok) {
      accept(r.data);
      notice = stamped(
        changed.some((x) => x.definition.restartRequired) ? text.savedRestart : t.saveBar.saved,
      );
    } else await failure(r.error);
    busy = false;
  }
  function discard() {
    if (snapshot) accept(snapshot);
  }
  onMount(() => void load());
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title={text.title} description={text.precedence}>
    {#snippet actions()}
      {#if loadedAt}<span class="text-muted-foreground text-sm"
          >{text.asOf.replace('{time}', formatClock(loadedAt))}</span
        >{/if}
      <Button
        type="button"
        variant="outline"
        size="icon"
        class="size-11 sm:size-9"
        disabled={busy}
        aria-label={text.reloadIcon}
        title={text.reload}
        onclick={() => void load()}><NavIcon name="refresh" size={18} /></Button
      >
    {/snippet}
  </PageHeader>
  {#if error && snapshot}<Banner tone="danger">{error}</Banner>{/if}
  {#if !snapshot}
    {#if error}
      <ErrorState title={ui.loadFailed} message={error} onretry={() => void load()} {busy} />
    {:else}
      <div
        aria-busy="true"
        class="bg-card ring-1 ring-foreground/10 rounded-xl flex flex-col gap-4 p-5"
      >
        <span class="sr-only" role="status">{t.states.loading}</span>
        <Skeleton class="h-5 w-40" /><Skeleton class="h-10" /><Skeleton class="h-10" />
      </div>
    {/if}
  {:else}
    <div class="flex flex-wrap items-start gap-3">
      <SearchField
        id="settings-search"
        label={ui.search}
        placeholder={ui.searchPlaceholder}
        bind:value={query}
      />
      <Select
        id="settings-source"
        aria-label={ui.source}
        bind:value={sourceFilter}
        class="w-full sm:w-48"
      >
        <option value="">{ui.allSources}</option>
        {#each Object.entries(ui.sources) as [key, label] (key)}<option value={key}>{label}</option
          >{/each}
      </Select>
    </div>
    {#if groupCounts.length > 0}
      <nav aria-label={text.groupsLabel} class="flex flex-wrap gap-2">
        {#each groupCounts as { g, n } (g)}
          <a
            href={`#${slug(g)}`}
            class="border-border bg-card hover:bg-muted inline-flex min-h-8 items-center gap-1.5 rounded-full border px-3 text-xs font-medium"
            >{g}<span class="text-muted-foreground">{n}</span></a
          >
        {/each}
      </nav>
    {/if}
    <p class="sr-only" role="status">{ui.count.replace('{n}', String(visible.length))}</p>
    <form id="settings-form" onsubmit={save} class="flex flex-col gap-5" aria-busy={busy}>
      {#each groups as group, index (group)}
        {@const items = visible.filter((x) => x.definition.group === group)}
        {#if items.length}
          <FormSection title={group} {index} id={slug(group)}>
            <div class="grid gap-x-6 gap-y-6 md:grid-cols-2">
              {#each items as item (item.definition.key)}
                {@const source = sourceOf(item)}
                <div data-setting={item.definition.key} class="flex flex-col gap-2">
                  <Row
                    id={item.definition.key}
                    label={item.definition.key}
                    hint={`${ui.envName}: ${item.definition.envName}${item.definition.minimum !== undefined ? ` · ${ui.range}: ${item.definition.minimum}–${item.definition.maximum}` : ''}`}
                  >
                    <Input
                      id={item.definition.key}
                      type={item.definition.sensitive ? 'password' : 'text'}
                      bind:value={values[item.definition.key]}
                      disabled={busy || item.locked}
                      inputmode={item.definition.type === 'integer' ? 'numeric' : 'text'}
                      class="font-mono"
                    />
                  </Row>
                  <p class="flex flex-wrap items-center gap-2">
                    <span class="text-muted-foreground text-xs">{text.source}:</span>
                    <StatusChip tone={tones[source]} label={ui.sources[source]} />
                    <span class="sr-only">{ui.sourceLong[source]}</span>
                    {#if item.locked}<StatusChip tone="idle" label={text.locked} />{/if}
                    {#if item.definition.restartRequired}<StatusChip
                        tone="warn"
                        label={text.restart}
                      />{/if}
                  </p>
                </div>
              {/each}
            </div>
          </FormSection>
        {/if}
      {/each}
      {#if !snapshot.items.length}
        <Panel>
          <EmptyState title={text.emptyTitle} description={text.emptyHint} icon="settings" />
        </Panel>
      {:else if (query || sourceFilter) && !visible.length}
        <Panel>
          <EmptyState title={ui.noMatch} icon="search">
            {#snippet action()}
              <Button type="button" variant="outline" onclick={resetFilters}
                >{text.resetFilter}</Button
              >
            {/snippet}
          </EmptyState>
        </Panel>
      {:else if !query && !sourceFilter && emptyGroups.length}
        <details class="text-muted-foreground text-sm">
          <summary class="min-h-8 cursor-pointer py-1 font-medium">{text.noExistingTitle}</summary>
          <p class="mt-2 mb-1">{text.noExistingEnv}</p>
          <ul class="m-0 flex list-disc flex-col gap-0.5 pl-5">
            {#each emptyGroups as g (g)}<li>{g}</li>{/each}
          </ul>
        </details>
      {/if}
    </form>
    <SaveBar dirty={dirty > 0} {busy} form="settings-form" ondiscard={discard} status={notice} />
  {/if}
</div>
