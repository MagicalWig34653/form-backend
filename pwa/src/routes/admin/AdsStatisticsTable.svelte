<script lang="ts">
  import type { AdsStatistics } from '$lib/api/admin';
  import { t } from '$lib/i18n';
  import { Table } from '$lib/components/ui/table';
  let { stats }: { stats: AdsStatistics } = $props();
  const percent = (value: number | null): string =>
    value === null
      ? '—'
      : new Intl.NumberFormat('de', { style: 'percent', maximumFractionDigits: 1 }).format(value);
</script>

<p class="text-muted-foreground text-sm">
  {stats.from} – {stats.to} · {t.adsStatistics.period}
</p>
{#if stats.groups.length}
  <div class="border-border overflow-hidden rounded-lg border">
    <Table label={t.adsStatistics.title} class="text-sm">
      <caption class="sr-only">{t.adsStatistics.title}</caption>
      <thead class="bg-muted/60 text-muted-foreground">
        <tr>
          <th scope="col" class="text-left">{t.adsStatistics.segment}</th>
          <th scope="col" class="text-right">{t.admin.stats.visits}</th>
          <th scope="col" class="text-right">{t.admin.stats.submits}</th>
          <th scope="col" class="text-right">{t.admin.stats.conversion}</th>
        </tr>
      </thead>
      <tbody>
        {#each stats.groups as group (group.segment)}
          <tr>
            <th scope="row" class="text-left font-normal">{t.adsStatistics[group.segment]}</th>
            <td class="text-right tabular-nums">{group.visits}</td>
            <td class="text-right tabular-nums">{group.submits}</td>
            <td class="text-right tabular-nums">{percent(group.conversion)}</td>
          </tr>
        {/each}
      </tbody>
    </Table>
  </div>
{:else}<p>{t.adsStatistics.empty}</p>{/if}
{#if stats.suppressed}<p class="text-sm">{t.adsStatistics.suppressed}</p>{/if}
<p class="text-muted-foreground text-sm">
  {t.adsStatistics.privacy}
  {t.adsStatistics.campaigns}
</p>
