<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { describeError, needsFreshLogin, loadFailureText } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { formPath } from '$lib/routes';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import SaveBar from '$lib/components/admin/SaveBar.svelte';
  import SaveStatus from '$lib/components/admin/SaveStatus.svelte';
  import { confirmAction } from '$lib/confirm.svelte';

  let {
    tenant,
    form,
    canWrite = true,
    ondirty,
  }: {
    tenant: string;
    form: string;
    canWrite?: boolean;
    ondirty?: (dirty: boolean) => void;
  } = $props();
  const r = t.retention;
  const formId = 'retention-form';

  let loaded = $state(false);
  let loadError = $state('');
  let saved = $state<number | null>(null);
  let days = $state('');
  let busy = $state(false);
  let status = $state('');
  let statusKind = $state<'ok' | 'error'>('ok');
  let savedAt = $state<Date | null>(null);
  /** Imported (legacy) submissions carry no due date; applying the period to them needs an explicit confirmation. */
  let importedOpen = $state(0);
  let dueNowImported = $state<number | null>(null);
  let applyImported = $state(false);

  /** The period is mandatory (server default 72 h = 3 days): there is no way to switch the deletion off. */
  /** `bind:value` on a number input yields a number (or null when empty), so normalise to text first. */
  const text = $derived(String(days ?? '').trim());
  const parsed = $derived(text === '' ? null : Number(text));
  const valid = $derived(Number.isInteger(parsed) && parsed! >= 1 && parsed! <= 3650);
  const target = $derived(valid ? parsed : null);
  /** Shortening deletes existing submissions: the user has to confirm. */
  const shortens = $derived(target !== null && saved !== null && target < saved);
  const dirty = $derived(loaded && (text !== String(saved) || applyImported));
  $effect(() => ondirty?.(dirty));

  /** Dry run: how many imported submissions would be due at once under the typed period (nothing is written). */
  $effect(() => {
    const d = target;
    if (!loaded || d === null || importedOpen === 0) return void (dueNowImported = null);
    let current = true;
    void adminApi.setRetention(tenant, form, d, { dryRun: true }).then((res) => {
      if (current) dueNowImported = res.ok ? (res.data.dueNowImported ?? 0) : null;
    });
    return () => (current = false);
  });

  async function load(): Promise<void> {
    loadError = '';
    const res = await adminApi.retention(tenant, form);
    if (res.ok) {
      saved = res.data.days;
      importedOpen = res.data.importedWithoutDeadline ?? 0;
      days = String(saved);
      loaded = true;
    } else if (!handleSessionError(res.error)) loadError = loadFailureText(res.error, r.loadFailed);
  }

  async function save(event?: SubmitEvent): Promise<void> {
    event?.preventDefault();
    if (busy || !dirty) return;
    if (!valid || target === null) {
      status = r.invalid;
      statusKind = 'error';
      return;
    }
    // One dialog naming every consequence (1698259A): shortening and/or including imported rows.
    const importedText = r.importedConfirmBody
      .replace('{n}', String(dueNowImported ?? 0))
      .replace('{d}', String(target));
    const shortenText = r.confirmBody.replace('{n}', String(target));
    if (shortens || applyImported) {
      const ok = await confirmAction({
        title: shortens ? r.confirmTitle : r.importedConfirmTitle,
        description:
          shortens && applyImported
            ? `${shortenText} ${importedText}`
            : shortens
              ? shortenText
              : importedText,
        confirmLabel: shortens ? r.confirmLabel : r.importedConfirmLabel,
        destructive: true,
      });
      if (!ok) return;
    }
    busy = true;
    status = '';
    const res = applyImported
      ? await adminApi.setRetention(tenant, form, target, { applyToImported: true })
      : await adminApi.setRetention(tenant, form, target);
    busy = false;
    if (!res.ok) {
      if (needsFreshLogin(res.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(res.error)) {
        status = describeError(res.error);
        statusKind = 'error';
      }
      return;
    }
    saved = target;
    importedOpen = res.data.importedWithoutDeadline ?? 0;
    applyImported = false;
    savedAt = new Date();
    status = '';
    statusKind = 'ok';
  }

  function discard(): void {
    days = saved === null ? '' : String(saved);
    applyImported = false;
    status = '';
  }
  $effect(() => {
    void days;
    if (dirty && status === t.admin.entries.retentionSaved) status = '';
  });

  onMount(() => void load());
</script>

<Panel title={r.title} description={r.description} hint={r.hint}>
  {#snippet actions()}
    {#if loaded}
      <SaveStatus
        state={busy
          ? 'saving'
          : statusKind === 'error' && status
            ? 'error'
            : dirty
              ? 'dirty'
              : savedAt
                ? 'saved'
                : 'idle'}
        at={savedAt}
        error={statusKind === 'error' ? status : ''}
        idle={t.saveStatus.idle}
      />
    {/if}
  {/snippet}
  {#if loadError}
    <Banner tone="danger">
      {loadError}
      {#snippet action()}
        <Button variant="outline" onclick={() => void load()}>{t.admin.retry}</Button>
      {/snippet}
    </Banner>
  {:else if !loaded}
    <div aria-busy="true" class="flex flex-col gap-3">
      <span class="sr-only" role="status">{t.admin.loading}</span>
      <Skeleton class="h-10 w-72" /><Skeleton class="h-10 w-48" />
    </div>
  {:else}
    <form id={formId} onsubmit={(e) => void save(e)} class="flex max-w-[560px] flex-col gap-5">
      <p class="text-muted-foreground m-0 text-sm">{r.standardHint}</p>
      <Row id="retention-days" label={r.days} hint={r.daysHint}>
        <div class="flex flex-col gap-2">
          <Input
            id="retention-days"
            type="number"
            min="1"
            max="3650"
            class="w-32"
            bind:value={days}
            disabled={!canWrite || busy}
          />
          <div class="flex flex-wrap gap-2" role="group" aria-label={r.presets}>
            {#each [3, 30, 90, 365] as preset (preset)}
              <Button
                type="button"
                variant={Number(days) === preset ? 'default' : 'outline'}
                size="sm"
                aria-pressed={Number(days) === preset}
                disabled={!canWrite || busy}
                onclick={() => (days = String(preset))}
                >{preset === 365
                  ? r.presetYear
                  : r.presetDays.replace('{n}', String(preset))}</Button
              >
            {/each}
          </div>
        </div>
      </Row>
      {#if importedOpen > 0}
        <div class="flex flex-col gap-3" data-testid="retention-imported">
          <Banner tone="warn">{r.importedNoDeadline.replace('{n}', String(importedOpen))}</Banner>
          {#if dueNowImported !== null}
            <p class="m-0 text-sm" data-testid="retention-imported-due">
              {r.importedDueNow
                .replace('{n}', String(dueNowImported))
                .replace('{d}', String(target))}
            </p>
          {/if}
          <label class="flex items-start gap-2 text-sm">
            <input
              type="checkbox"
              class="mt-1"
              bind:checked={applyImported}
              disabled={!canWrite || busy}
            />
            <span>{r.importedApply}</span>
          </label>
        </div>
      {/if}
      {#if dirty && shortens}<Banner tone="warn"
          >{r.shortenWarn.replace('{n}', String(target))}</Banner
        >{/if}
    </form>
  {/if}
  {#if loaded}
    <p class="text-muted-foreground m-0 mt-5 border-t pt-4 text-sm">
      {saved === null ? '' : r.current.replace('{n}', String(saved))} ·
      <a
        class="underline underline-offset-4"
        href={formPath(tenant, form, 'entries')}
        onclick={(e) => {
          if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
          e.preventDefault();
          router.navigate(formPath(tenant, form, 'entries'));
        }}>{r.toEntries}</a
      >
    </p>
  {/if}
</Panel>
<SaveBar
  {dirty}
  {busy}
  form={formId}
  ondiscard={discard}
  status=""
  saveLabel={t.admin.entries.retentionSave}
/>
