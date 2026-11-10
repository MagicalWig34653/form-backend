<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import { router } from '$lib/router.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { formPath } from '$lib/routes';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Switch } from '$lib/components/ui/switch';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import SaveBar from '$lib/components/admin/SaveBar.svelte';

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
  let enabled = $state(false);
  let days = $state('');
  let busy = $state(false);
  let status = $state('');
  let statusKind = $state<'ok' | 'error'>('ok');

  const parsed = $derived(days.trim() === '' ? null : Number(days));
  const valid = $derived(!enabled || (Number.isInteger(parsed) && parsed! >= 1 && parsed! <= 3650));
  const target = $derived(enabled ? parsed : null);
  const dirty = $derived(loaded && target !== saved);
  $effect(() => ondirty?.(dirty));

  async function load(): Promise<void> {
    loadError = '';
    const res = await adminApi.retention(tenant, form);
    if (res.ok) {
      saved = res.data.days;
      enabled = saved !== null;
      days = saved === null ? '' : String(saved);
      loaded = true;
    } else if (!handleSessionError(res.error)) loadError = r.loadFailed;
  }

  async function save(event?: SubmitEvent): Promise<void> {
    event?.preventDefault();
    if (busy || !dirty) return;
    if (!valid) {
      status = r.invalid;
      statusKind = 'error';
      return;
    }
    busy = true;
    status = '';
    const res = await adminApi.setRetention(tenant, form, target);
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
    status = t.admin.entries.retentionSaved;
    statusKind = 'ok';
  }

  function discard(): void {
    enabled = saved !== null;
    days = saved === null ? '' : String(saved);
    status = '';
  }
  $effect(() => {
    void enabled;
    void days;
    if (dirty && status === t.admin.entries.retentionSaved) status = '';
  });

  onMount(() => void load());
</script>

<Panel title={r.title} description={r.description}>
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
      <label class="flex min-h-10 items-center gap-3 text-sm font-medium">
        <Switch bind:checked={enabled} disabled={!canWrite || busy} />{r.autoDelete}
      </label>
      {#if enabled}
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
              {#each [30, 90, 365] as preset (preset)}
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
      {:else}
        <p class="text-muted-foreground m-0 text-sm">{r.autoDeleteOff}</p>
      {/if}
      <p class="text-muted-foreground m-0 text-sm leading-5">{r.hint}</p>
    </form>
  {/if}
  {#if loaded}
    <p class="text-muted-foreground m-0 mt-5 border-t pt-4 text-sm">
      {saved === null ? r.currentOff : r.current.replace('{n}', String(saved))} ·
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
  {status}
  {statusKind}
  saveLabel={t.admin.entries.retentionSave}
/>
