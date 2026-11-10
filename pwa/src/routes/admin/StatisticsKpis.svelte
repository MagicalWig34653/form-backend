<script lang="ts">
  import { formatPeriod } from '$lib/format';
  import { t } from '$lib/i18n';
  import type { Statistics } from '$lib/api/admin';
  import KpiTile from './overview/KpiTile.svelte';
  import CardHeader from '$lib/components/admin/CardHeader.svelte';
  import { conversionSeries, conversionWeeks, weekOverWeek } from '$lib/stats/series';
  import { countDelta, formatPercent, pointsDelta } from '$lib/stats/delta';

  let {
    stats,
    days,
    onperiod,
  }: { stats: Statistics; days: number; onperiod?: (days: number) => void } = $props();
  const periods = [14, 30];
  const ui = t.admin.statisticsPage;
  const metrics = ['visits', 'begins', 'submits', 'abandons'] as const;
  const conversion = $derived(stats.visits === 0 ? null : stats.submits / stats.visits);
  const visitsSeries = $derived(stats.days.map((d) => d.visits));
  const submitsSeries = $derived(stats.days.map((d) => d.submits));
  const convSeries = $derived(conversionSeries(visitsSeries, submitsSeries));
</script>

<CardHeader
  class="mb-4"
  title={ui.title}
  description={`${t.admin.stats.range.replace('{n}', String(days))} · ${ui.period.replace('{period}', formatPeriod(stats.from, stats.to))}`}
>
  {#snippet actions()}
    {#if onperiod}
      <div role="group" aria-label={ui.periodSwitch} class="flex gap-1">
        {#each periods as n (n)}
          <button
            type="button"
            aria-pressed={days === n}
            class={`focus-visible:ring-ring min-h-9 rounded-md border px-3 text-sm font-medium focus-visible:ring-2 focus-visible:outline-none ${days === n ? 'bg-primary text-primary-foreground border-primary' : 'hover:bg-secondary'}`}
            onclick={() => onperiod(n)}>{ui.periodDays.replace('{n}', String(n))}</button
          >
        {/each}
      </div>
    {/if}
    <span
      class="bg-muted text-muted-foreground rounded-full px-2.5 py-0.5 text-sm leading-[18px] font-medium"
      >{ui.scope}</span
    >
  {/snippet}
</CardHeader>
<div class="grid grid-cols-2 gap-4 sm:grid-cols-5" role="group" aria-label={t.admin.stats.total}>
  {#each metrics as metric, n (metric)}
    {@const series = stats.days.map((d) => d[metric])}
    <KpiTile
      index={n}
      label={t.admin.stats[metric]}
      hint={t.admin.statisticsPage.hints[metric]}
      value={stats[metric]}
      series={series.length > 2 ? series : undefined}
      seriesLabel={t.overview.sparkLabel
        .replace('{metric}', t.admin.stats[metric])
        .replace('{values}', series.join(', '))}
      delta={countDelta(weekOverWeek(series))}
    />
  {/each}
  <KpiTile
    class="col-span-2 sm:col-span-1"
    index={4}
    label={t.admin.stats.conversion}
    hint={t.overview.hintConversion}
    value={conversion}
    format={formatPercent}
    series={convSeries.length > 2 ? convSeries : undefined}
    seriesLabel={t.overview.sparkLabel
      .replace('{metric}', t.admin.stats.conversion)
      .replace('{values}', convSeries.map((v) => (v === null ? '–' : formatPercent(v))).join(', '))}
    delta={pointsDelta(conversionWeeks(visitsSeries, submitsSeries))}
    reason={t.overview.noConversion}
  />
</div>
