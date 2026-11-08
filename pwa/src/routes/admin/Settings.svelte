<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import FormSection from '$lib/components/admin/FormSection.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import ErrorState from '$lib/components/admin/ErrorState.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip, { type Tone } from '$lib/components/admin/StatusChip.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
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
  const groups = [
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
  const groupCounts = $derived(
    groups
      .map((g) => ({ g, n: visible.filter((x) => x.definition.group === g).length }))
      .filter((x) => x.n > 0),
  );
  const emptyGroups = $derived(
    groups.filter((g) => !(snapshot?.items ?? []).some((x) => x.definition.group === g)),
  );
  const slug = (g: string) => 'grp-' + g.toLowerCase().replace(/[^a-z0-9]+/g, '-');
  async function failure(e: Parameters<typeof describeError>[0]) {
    if (e.status === 409) error = text.conflict;
    else if (needsFreshLogin(e)) await reauthenticate('/settings');
    else if (!handleSessionError(e)) error = describeError(e);
  }
  function accept(data: Snapshot) {
    snapshot = data;
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
      notice = changed.some((x) => x.definition.restartRequired) ? text.savedRestart : text.saved;
    } else await failure(r.error);
    busy = false;
  }
  onMount(() => void load());
</script>

<div class="mx-auto flex w-full max-w-[1040px] flex-col gap-6">
  <PageHeader title={text.title} description={text.precedence}>
    {#snippet badges()}
      <StatusChip tone="info" label={ui.precedenceChain} />
    {/snippet}
    {#snippet actions()}
      <Button type="button" variant="outline" disabled={busy} onclick={() => void load()}
        >{text.reload}</Button
      >
    {/snippet}
  </PageHeader>
  {#if error && snapshot}<Banner tone="danger">{error}</Banner>{/if}
  {#if notice}<Banner tone="ok">{notice}</Banner>{/if}
  {#if !snapshot}
    {#if error}
      <ErrorState title={ui.loadFailed} message={error} onretry={() => void load()} {busy} />
    {:else}
      <div aria-busy="true" class="surface-card flex flex-col gap-4 p-5">
        <span class="sr-only" role="status">{t.states.loading}</span>
        <Skeleton class="h-5 w-40" /><Skeleton class="h-10" /><Skeleton class="h-10" />
      </div>
    {/if}
  {:else}
    <div class="surface-card flex flex-wrap items-end gap-3 p-4">
      <div class="min-w-0 flex-1 basis-56">
        <label for="settings-search" class="mb-1.5 block text-sm font-medium">{ui.search}</label>
        <div class="relative">
          <span
            aria-hidden="true"
            class="text-muted-foreground pointer-events-none absolute top-1/2 left-3 -translate-y-1/2"
            ><NavIcon name="search" size={16} /></span
          >
          <Input
            id="settings-search"
            type="search"
            bind:value={query}
            class="pl-9"
            autocomplete="off"
            aria-describedby="settings-search-hint"
          />
        </div>
        <p id="settings-search-hint" class="text-muted-foreground mt-1 text-xs">{ui.searchHint}</p>
      </div>
      <div class="w-full sm:w-48">
        <label for="settings-source" class="mb-1.5 block text-sm font-medium">{ui.source}</label>
        <Select id="settings-source" bind:value={sourceFilter}>
          <option value="">{ui.allSources}</option>
          {#each Object.entries(ui.sources) as [key, label] (key)}<option value={key}
              >{label}</option
            >{/each}
        </Select>
      </div>
    </div>
    {#if groupCounts.length > 1}
      <nav aria-label="Gruppen" class="flex flex-wrap gap-2">
        {#each groupCounts as { g, n } (g)}
          <a
            href={`#${slug(g)}`}
            class="border-border bg-card hover:bg-surface-sunken inline-flex min-h-8 items-center gap-1.5 rounded-full border px-3 text-xs font-medium"
            >{g}<span class="text-muted-foreground">{n}</span></a
          >
        {/each}
      </nav>
    {/if}
    <p class="sr-only" role="status">{ui.count.replace('{n}', String(visible.length))}</p>
    <form onsubmit={save} class="flex flex-col gap-5" aria-busy={busy}>
      {#each groups as group, index (group)}
        {@const items = visible.filter((x) => x.definition.group === group)}
        {#if items.length}
          <FormSection title={group} {index} id={slug(group)}>
            <div class="grid gap-4 md:grid-cols-2">
              {#each items as item (item.definition.key)}
                {@const source = sourceOf(item)}
                <div
                  data-setting={item.definition.key}
                  class="border-border-subtle bg-surface-sunken/50 flex flex-col gap-2 rounded-lg border p-3"
                >
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
      {#if (query || sourceFilter) && !visible.length}
        <EmptyState title={ui.noMatch} icon="search" />
      {:else if !query && !sourceFilter && emptyGroups.length}
        <p class="text-muted-foreground text-sm">
          {text.noExistingEnv} ({emptyGroups.join(', ')})
        </p>
      {/if}
      <div
        class="glass-bar border-border-subtle sticky bottom-0 z-10 -mx-4 flex flex-wrap items-center justify-between gap-3 border-t px-4 py-3 md:-mx-8 md:px-8"
      >
        <span class="text-muted-foreground text-sm" aria-live="polite"
          >{dirty ? `${ui.dirty}: ${dirty}` : ''}</span
        >
        <Button type="submit" disabled={busy}>{text.save}</Button>
      </div>
    </form>
  {/if}
</div>
