<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import type { Statistics } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { setTitle, title } from '$lib/draft/doc';
  import { describeError } from '$lib/admin/describe';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import DraftGate from './DraftGate.svelte';
  import StatisticsChart from './StatisticsChart.svelte';
  import AdsStatisticsPanel from './AdsStatisticsPanel.svelte';

  let { editor, tenant, form }: { editor: Editor; tenant: string; form: string } = $props();

  const DAYS = 30;
  let stats = $state<Statistics | null>(null);
  let statsLoading = $state(true);
  let statsError = $state('');
  let slow = $state(false);
  let generation = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  async function loadStats(): Promise<void> {
    const current = ++generation;
    statsLoading = true;
    statsError = '';
    slow = false;
    timer = setTimeout(() => {
      slow = true;
    }, 3000);
    const r = await adminApi.statistics(tenant, form, DAYS);
    if (generation !== current) return;
    clearTimeout(timer);
    statsLoading = false;
    if (r.ok) stats = r.data;
    else if (!handleSessionError(r.error))
      statsError =
        r.error.status === 403
          ? t.lists.forbidden
          : r.error.status === 404
            ? t.lists.notFound
            : t.lists.failed;
  }
  onMount(() => void loadStats());
  onDestroy(() => {
    generation++;
    clearTimeout(timer);
  });

  let text = $state('');
  let ok = $state('');
  $effect(() => {
    if (editor.draft) text = title(editor.draft.document);
  });

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    ok = '';
    const err = await editor.apply((d) => setTitle(d, text));
    if (!err) ok = t.admin.saved;
  }
</script>

<section aria-label={t.lists.readStatus} class="surface-card px-5 py-4">
  <dl class="grid gap-4 sm:grid-cols-3">
    <div>
      <dt class="text-muted-foreground text-[length:var(--fs-small)]">{t.lists.publication}</dt>
      <dd class="mt-1.5">
        <StatusChip
          tone={editor.detail?.currentReleaseVersion != null ? 'ok' : 'idle'}
          label={editor.detail?.currentReleaseVersion != null
            ? t.lists.version.replace('{n}', String(editor.detail.currentReleaseVersion))
            : t.lists.unpublished}
        />
      </dd>
    </div>
    <div>
      <dt class="text-muted-foreground text-[length:var(--fs-small)]">{t.lists.status}</dt>
      <dd class="mt-1.5">
        <StatusChip
          tone={editor.detail?.active ? 'ok' : 'idle'}
          label={editor.detail?.active ? t.lists.active : t.lists.inactive}
        />
      </dd>
    </div>
    <div>
      <dt class="text-muted-foreground text-[length:var(--fs-small)]">{t.lists.draft}</dt>
      <dd class="mt-1.5">
        <StatusChip
          tone={editor.draft ? 'info' : 'idle'}
          label={editor.draft
            ? t.lists.draftState.replace('{n}', String(editor.draft.revision))
            : editor.error
              ? t.lists.unknown
              : t.admin.form.noDraft}
        />
      </dd>
    </div>
  </dl>
</section>
{#if !editor.detail?.currentReleaseId}
  <Banner tone="info">{t.lists.noRelease}</Banner>
{:else}
  <div class="flex max-w-prose flex-col gap-1.5">
    <div>
      <Button
        type="button"
        variant="outline"
        disabled={editor.saving}
        onclick={() => void editor.createDraft()}>{t.admin.form.newDraft}</Button
      >
    </div>
    <p class="text-muted-foreground text-[length:var(--fs-small)]">{t.admin.form.newDraftHint}</p>
  </div>
{/if}

<Panel title={t.admin.form.draft}>
  <DraftGate {editor}>
    <form onsubmit={(e) => void save(e)} class="mt-3 flex max-w-md flex-col gap-3">
      <Row id="draft-title" label={t.admin.form.title}>
        <Input id="draft-title" bind:value={text} required maxlength={190} />
      </Row>
      <Notice
        message={editor.error ? describeError(editor.error) : ok}
        kind={editor.error ? 'error' : 'ok'}
      />
      <div class="flex items-center gap-3">
        <Button type="submit" disabled={editor.saving}>{t.admin.form.titleSave}</Button>
        <span class="text-muted-foreground text-[length:var(--fs-small)]"
          >{t.admin.form.revision.replace('{n}', String(editor.draft?.revision ?? 0))}</span
        >
      </div>
    </form>
  </DraftGate>
</Panel>

<section
  id="statistics"
  aria-label={t.lists.statsLabel}
  aria-busy={statsLoading}
  class="flex scroll-mt-20 flex-col gap-4"
>
  <div role="status" class="text-muted-foreground text-[length:var(--fs-small)]">
    {statsLoading ? (slow ? t.lists.slow : t.lists.statsLoading) : ''}
  </div>
  {#if statsLoading && !stats}<Skeleton class="min-h-48 rounded-[var(--r-card)]" />{/if}
  {#if statsError}
    <Banner tone="danger">
      {statsError}
      {#snippet action()}
        <Button variant="outline" onclick={() => void loadStats()}>{t.lists.retry}</Button>
      {/snippet}
    </Banner>
  {/if}
  {#if stats}
    <StatisticsChart {stats} days={DAYS} /><AdsStatisticsPanel {tenant} {form} />
  {/if}
</section>
