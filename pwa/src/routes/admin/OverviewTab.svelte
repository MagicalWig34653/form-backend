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

<section aria-label={t.lists.readStatus} class="bg-card border-border rounded-xl border p-5">
  <dl class="grid gap-4 sm:grid-cols-3">
    <div>
      <dt class="text-muted-foreground text-sm">{t.lists.publication}</dt>
      <dd class="mt-1 font-medium">
        {editor.detail?.currentReleaseVersion != null
          ? t.lists.version.replace('{n}', String(editor.detail.currentReleaseVersion))
          : t.lists.unpublished}
      </dd>
    </div>
    <div>
      <dt class="text-muted-foreground text-sm">{t.lists.status}</dt>
      <dd class="mt-1 font-medium">{editor.detail?.active ? t.lists.active : t.lists.inactive}</dd>
    </div>
    <div>
      <dt class="text-muted-foreground text-sm">{t.lists.draft}</dt>
      <dd class="mt-1 font-medium">
        {editor.draft
          ? t.lists.draftState.replace('{n}', String(editor.draft.revision))
          : editor.error
            ? t.lists.unknown
            : t.admin.form.noDraft}
      </dd>
    </div>
  </dl>
</section>
{#if !editor.detail?.currentReleaseId}
  <p>{t.lists.noRelease}</p>
{:else}
  <div class="flex max-w-prose flex-col gap-1">
    <div>
      <Button
        type="button"
        variant="outline"
        disabled={editor.saving}
        onclick={() => void editor.createDraft()}>{t.admin.form.newDraft}</Button
      >
    </div>
    <p class="text-muted-foreground text-xs">{t.admin.form.newDraftHint}</p>
  </div>
{/if}

<section class="bg-card border-border flex flex-col gap-5 rounded-xl border p-6">
  <h2 class="text-lg font-medium">{t.admin.form.draft}</h2>
  <DraftGate {editor}>
    <form onsubmit={(e) => void save(e)} class="flex max-w-md flex-col gap-3">
      <Row id="draft-title" label={t.admin.form.title}>
        <Input id="draft-title" bind:value={text} required maxlength={190} />
      </Row>
      <Notice
        message={editor.error ? describeError(editor.error) : ok}
        kind={editor.error ? 'error' : 'ok'}
      />
      <div class="flex items-center gap-3">
        <Button type="submit" disabled={editor.saving}>{t.admin.form.titleSave}</Button>
        <span class="text-muted-foreground text-xs"
          >{t.admin.form.revision.replace('{n}', String(editor.draft?.revision ?? 0))}</span
        >
      </div>
    </form>
  </DraftGate>
</section>

<section
  id="statistics"
  aria-label={t.lists.statsLabel}
  aria-busy={statsLoading}
  class="scroll-mt-20"
>
  <div role="status" class="text-muted-foreground text-sm">
    {statsLoading ? (slow ? t.lists.slow : t.lists.statsLoading) : ''}
  </div>
  {#if statsLoading && !stats}<div
      class="bg-muted min-h-48 rounded-xl"
      aria-hidden="true"
    ></div>{/if}
  {#if statsError}<p role="alert">{statsError}</p>
    <Button variant="outline" onclick={() => void loadStats()}>{t.lists.retry}</Button>{/if}
  {#if stats}
    <section class="bg-card border-border rounded-xl border p-6">
      <StatisticsChart {stats} days={DAYS} /><AdsStatisticsPanel {tenant} {form} />
    </section>
  {/if}
</section>
