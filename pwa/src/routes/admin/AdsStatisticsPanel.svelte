<script lang="ts">
  import { adminApi } from '$lib/api';
  import type { AdsStatistics } from '$lib/api/admin';
  import { t } from '$lib/i18n';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import AdsStatisticsTable from './AdsStatisticsTable.svelte';
  let { tenant, form }: { tenant: string; form: string } = $props();
  let stats = $state<AdsStatistics | null>(null);
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
    loading = true;
    void adminApi.adsStatistics(currentTenant, currentForm).then((r) => {
      if (!active) return;
      loading = false;
      if (r.ok) stats = r.data;
      else if (!handleSessionError(r.error)) error = describeError(r.error);
    });
    return () => {
      active = false;
    };
  });
</script>

<section
  class="border-border mt-6 space-y-3 border-t pt-4"
  aria-label={t.adsStatistics.title}
  aria-busy={loading}
>
  <h3 class="font-semibold">{t.adsStatistics.title}</h3>
  {#if loading}<p role="status">{t.admin.loading}</p>{/if}
  {#if error}<p role="alert">{error}</p>
    <button class="min-h-11 underline" onclick={() => retry++}>{t.admin.retry}</button>{/if}
  {#if stats}<AdsStatisticsTable {stats} />{/if}
</section>
