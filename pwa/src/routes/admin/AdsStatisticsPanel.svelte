<script lang="ts">
  import { adminApi } from '$lib/api';
  import type { AdsStatistics } from '$lib/api/admin';
  import { t } from '$lib/i18n';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import AdsStatisticsTable from './AdsStatisticsTable.svelte';
  let { tenant, form }: { tenant: string; form: string } = $props();
  let stats = $state<AdsStatistics | null>(null);
  // Optional block: a missing evaluation is a hint, not an error.
  let unavailable = $state(false);
  let error = $state('');
  let loading = $state(true);
  let retry = $state(0);
  $effect(() => {
    const currentTenant = tenant,
      currentForm = form;
    void retry;
    let active = true;
    stats = null;
    error = '';
    unavailable = false;
    loading = true;
    void adminApi.adsStatistics(currentTenant, currentForm).then((r) => {
      if (!active) return;
      loading = false;
      if (r.ok) stats = r.data;
      else if (!handleSessionError(r.error)) {
        if (r.error.status === 404) unavailable = true;
        else error = describeError(r.error);
      }
    });
    return () => {
      active = false;
    };
  });
</script>

{#if stats && stats.groups.length === 0 && !stats.suppressed}
  <p
    role="status"
    class="text-muted-foreground m-0 flex flex-wrap items-center gap-x-2 text-sm leading-5"
  >
    <span class="shrink-0" aria-hidden="true"><NavIcon name="info" size={16} /></span>
    <span>{t.formUi.adsTitle}: {t.adsStatistics.empty}</span>
  </p>
{:else if unavailable}
  <p
    role="status"
    class="text-muted-foreground m-0 flex flex-wrap items-center gap-x-2 text-sm leading-5"
  >
    <span class="shrink-0" aria-hidden="true"><NavIcon name="info" size={16} /></span>
    <span>{t.formUi.adsTitle}: {t.formUi.adsUnavailable}</span>
    <button
      type="button"
      class="text-brand-ink inline-flex min-h-8 items-center rounded-md px-1 font-medium underline underline-offset-4"
      onclick={() => retry++}>{t.formUi.adsRetry}</button
    >
  </p>
{:else}
  <Panel title={t.formUi.adsTitle} description={t.formUi.adsHint}>
    <div class="flex flex-col gap-3" aria-busy={loading}>
      {#if loading}
        <p role="status" class="sr-only">{t.admin.loading}</p>
        <Skeleton class="h-4 w-2/3" />
        <Skeleton class="h-4 w-1/2" />
      {/if}
      {#if error}
        <p role="status" class="text-muted-foreground text-sm">{error}</p>
      {/if}
      {#if error}
        <button
          type="button"
          class="text-brand-ink -ml-1 inline-flex min-h-10 w-fit items-center rounded-md px-1 text-sm font-medium underline underline-offset-4"
          onclick={() => retry++}>{t.formUi.adsRetry}</button
        >
      {/if}
      {#if stats}<AdsStatisticsTable {stats} />{/if}
    </div>
  </Panel>
{/if}
