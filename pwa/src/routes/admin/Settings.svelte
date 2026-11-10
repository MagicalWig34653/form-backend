<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import FormSection from '$lib/components/admin/FormSection.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip, { type Tone } from '$lib/components/admin/StatusChip.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import SaveStatus from '$lib/components/admin/SaveStatus.svelte';
  import { Switch } from '$lib/components/ui/switch';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { formatClock } from '$lib/format';
  import SearchField from '$lib/components/admin/SearchField.svelte';
  interface Item {
    definition: {
      key: string;
      group: string;
      type: string;
      envName: string;
      minimum?: number;
      maximum?: number;
      defaultValue?: string;
      restartRequired: boolean;
      sensitive?: boolean;
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
  type GroupState = { state: 'saving' | 'saved' | 'error'; at?: Date };
  let groupState = $state<Record<string, GroupState>>({});
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
  const isDirty = (x: Item): boolean => !x.locked && values[x.definition.key] !== (x.value ?? '');
  const dirtyIn = (group: string): Item[] =>
    (snapshot?.items ?? []).filter((x) => x.definition.group === group && isDirty(x));
  const unitOf = (key: string): string => {
    const unit = ui.keys[key]?.unit;
    return unit ? ((ui.units as Record<string, string>)[unit] ?? '') : '';
  };
  const titleOf = (item: Item): string =>
    ui.keys[item.definition.key]?.title ?? item.definition.key;
  const shown = (value: string | undefined, type = ''): string =>
    type === 'boolean' ? (value === 'true' ? ui.on : ui.off) : value ? value : ui.emptyValue;
  const groupLabel = (g: string): string => (ui.groupTitles as Record<string, string>)[g] ?? g;
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
    groupState = {};
    const r = await http.request<Snapshot>('GET', '/settings');
    if (r.ok) accept(r.data);
    else await failure(r.error);
    busy = false;
  }
  async function save(group: string, e?: SubmitEvent) {
    e?.preventDefault();
    if (!snapshot || busy) return;
    const changed = dirtyIn(group);
    if (!changed.length) return;
    busy = true;
    error = '';
    notice = '';
    groupState[group] = { state: 'saving' };
    const r = await http.request<Snapshot>('PUT', '/settings', {
      body: {
        revision: snapshot.revision,
        values: Object.fromEntries(
          changed.map((x) => [x.definition.key, values[x.definition.key]]),
        ),
      },
    });
    if (r.ok) {
      // Other groups keep their pending edits; only the saved group takes the server's values.
      const pending = Object.fromEntries(
        (snapshot.items ?? [])
          .filter((x) => x.definition.group !== group && isDirty(x))
          .map((x) => [x.definition.key, values[x.definition.key] ?? '']),
      );
      accept(r.data);
      Object.assign(values, pending);
      groupState[group] = { state: 'saved', at: new Date() };
      notice = changed.some((x) => x.definition.restartRequired) ? text.savedRestart : '';
    } else {
      groupState[group] = { state: 'error' };
      await failure(r.error);
    }
    busy = false;
  }
  function discard(group: string) {
    if (!snapshot) return;
    for (const x of snapshot.items)
      if (x.definition.group === group) values[x.definition.key] = x.value ?? '';
    delete groupState[group];
  }
  function resetToDefault(item: Item) {
    if (item.definition.defaultValue !== undefined)
      values[item.definition.key] = item.definition.defaultValue;
  }
  const statusOf = (group: string): 'idle' | 'dirty' | 'saving' | 'saved' | 'error' => {
    const g = groupState[group];
    if (g?.state === 'saving') return 'saving';
    if (dirtyIn(group).length) return 'dirty';
    return g?.state ?? 'idle';
  };
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
      <nav aria-label={text.groupsLabel} class="flex flex-wrap items-center gap-2">
        <span class="text-muted-foreground text-xs">{ui.jumpTo}</span>
        {#each groupCounts as { g, n } (g)}
          <a
            href={`#${slug(g)}`}
            class="text-brand-ink hover:bg-muted focus-visible:ring-ring inline-flex min-h-8 items-center gap-1.5 rounded-md px-2 text-sm font-medium underline-offset-4 hover:underline focus-visible:ring-2 focus-visible:outline-none"
            >{groupLabel(g)}<span class="text-muted-foreground text-xs">{n}</span></a
          >
        {/each}
      </nav>
    {/if}
    <p class="sr-only" role="status">{ui.count.replace('{n}', String(visible.length))}</p>
    <div class="flex flex-col gap-5" aria-busy={busy}>
      {#each groups as group, index (group)}
        {@const items = visible.filter((x) => x.definition.group === group)}
        {@const pending = dirtyIn(group)}
        {#if items.length}
          <form id={`settings-${slug(group)}`} onsubmit={(e) => void save(group, e)}>
            <FormSection
              title={groupLabel(group)}
              {index}
              id={slug(group)}
              hint={ui.autoHint}
              class="scroll-mt-20"
            >
              {#snippet actions()}
                <SaveStatus
                  state={statusOf(group)}
                  at={groupState[group]?.at ?? null}
                  idle={ui.groupIdle}
                  error={error && groupState[group]?.state === 'error' ? error : ''}
                />
              {/snippet}
              <ul class="divide-border -my-2 flex list-none flex-col divide-y p-0">
                {#each items as item (item.definition.key)}
                  {@const source = sourceOf(item)}
                  {@const key = item.definition.key}
                  {@const def = item.definition.defaultValue}
                  <li
                    data-setting={key}
                    class="grid items-start gap-x-8 gap-y-2 py-3 sm:grid-cols-[minmax(0,1fr)_minmax(0,19rem)]"
                  >
                    <div class="min-w-0">
                      <label for={key} class="text-sm leading-5 font-medium">{titleOf(item)}</label>
                      {#if ui.keys[key]?.hint}<p
                          id={`${key}-hint`}
                          class="text-muted-foreground m-0 mt-0.5 text-sm leading-5"
                        >
                          {ui.keys[key]?.hint}
                        </p>{/if}
                      <p
                        class="text-muted-foreground m-0 mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs leading-5"
                      >
                        <span class="font-mono">{key}</span>
                        <span aria-hidden="true">·</span>
                        <span
                          >{item.definition.envName
                            ? ui.envLine.replace('{env}', item.definition.envName)
                            : ui.noEnv}</span
                        >
                        {#if def !== undefined}<span aria-hidden="true">·</span><span
                            >{ui.defaultLine.replace(
                              '{value}',
                              shown(def, item.definition.type),
                            )}</span
                          >{/if}
                        {#if item.definition.minimum !== undefined}<span aria-hidden="true">·</span
                          ><span
                            >{ui.range}: {item.definition.minimum}–{item.definition.maximum}</span
                          >{/if}
                        <StatusChip tone={tones[source]} label={ui.sources[source]} />
                        <span class="sr-only">{text.source}: {ui.sourceLong[source]}</span>
                        {#if item.definition.restartRequired}<StatusChip
                            tone="warn"
                            label={text.restart}
                          />{/if}
                      </p>
                    </div>
                    <div class="flex min-w-0 flex-col gap-1.5">
                      {#if item.definition.type === 'boolean'}
                        <label class="flex min-h-10 items-center gap-3 text-sm">
                          <Switch
                            id={key}
                            checked={values[key] === 'true'}
                            onchange={(e) =>
                              (values[key] = e.currentTarget.checked ? 'true' : 'false')}
                            disabled={busy || item.locked}
                            aria-describedby={ui.keys[key]?.hint ? `${key}-hint` : undefined}
                          />
                          {values[key] === 'true' ? ui.on : ui.off}
                        </label>
                      {:else if item.definition.type === 'level'}
                        <Select
                          id={key}
                          bind:value={values[key]}
                          disabled={busy || item.locked}
                          aria-describedby={ui.keys[key]?.hint ? `${key}-hint` : undefined}
                        >
                          {#each ['trace', 'debug', 'info', 'notice', 'warning', 'error', 'critical'] as level (level)}<option
                              value={level}>{level}</option
                            >{/each}
                        </Select>
                      {:else}
                        <div class="flex items-center gap-2">
                          <Input
                            id={key}
                            type={item.definition.sensitive ? 'password' : 'text'}
                            bind:value={values[key]}
                            disabled={busy || item.locked}
                            readonly={item.locked}
                            inputmode={item.definition.type === 'integer' ? 'numeric' : 'text'}
                            aria-describedby={ui.keys[key]?.hint ? `${key}-hint` : undefined}
                            class="min-w-0 flex-1 font-mono"
                          />
                          {#if unitOf(key)}<span class="text-muted-foreground shrink-0 text-sm"
                              >{unitOf(key)}</span
                            >{/if}
                        </div>
                      {/if}
                      {#if item.locked}
                        <p class="text-muted-foreground m-0 flex items-start gap-1.5 text-xs">
                          <span class="mt-0.5 shrink-0"><NavIcon name="locked" size={13} /></span
                          >{text.locked}. {ui.lockedNote}
                        </p>
                      {:else if def !== undefined && values[key] !== def}
                        <div>
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            class="-ml-2.5"
                            disabled={busy}
                            aria-label={ui.resetFieldLabel.replace('{name}', titleOf(item))}
                            onclick={() => resetToDefault(item)}>{ui.resetField}</Button
                          >
                        </div>
                      {/if}
                    </div>
                  </li>
                {/each}
              </ul>
              {#if pending.length > 0}
                <div class="border-border flex flex-wrap items-center gap-2 border-t pt-4">
                  <Button type="submit" disabled={busy || pending.length === 0}>{text.save}</Button>
                  <Button
                    type="button"
                    variant="ghost"
                    disabled={busy || pending.length === 0}
                    onclick={() => discard(group)}>{ui.discard}</Button
                  >
                </div>
              {/if}
            </FormSection>
          </form>
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
    </div>
    {#if notice}<Banner tone="info">{notice}</Banner>{/if}
  {/if}
</div>
