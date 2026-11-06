<script lang="ts">
  import { t } from '$lib/i18n';
  import type { Statistics } from '$lib/api/admin';

  let { stats, days }: { stats: Statistics; days: number } = $props();
  const ui = t.admin.statisticsPage;
  const metrics = ['visits', 'begins', 'submits', 'abandons'] as const;
  const max = $derived(Math.max(1, ...stats.days.flatMap((d) => metrics.map((m) => d[m]))));
  const conversion = $derived(stats.visits === 0 ? null : stats.submits / stats.visits);
  const hasEvents = $derived(metrics.some((metric) => stats[metric] > 0));
  const colors = [
    'var(--primary)',
    'var(--foreground)',
    'var(--muted-foreground)',
    'var(--destructive)',
  ];
  const percent = (value: number | null): string =>
    value === null
      ? '—'
      : new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 }).format(
          value,
        );
</script>

<header class="mb-5 flex flex-wrap items-start justify-between gap-3">
  <div>
    <h2 class="text-xl font-semibold">{ui.title}</h2>
    <p class="text-muted-foreground text-sm">{t.admin.stats.range.replace('{n}', String(days))}</p>
    <p class="text-muted-foreground text-xs">
      {ui.period.replace('{from}', stats.from).replace('{to}', stats.to)}
    </p>
  </div>
  <span class="rounded-md border px-3 py-1 text-sm">{ui.scope}</span>
</header>
<dl
  class="mb-5 grid grid-cols-2 gap-3 text-sm sm:grid-cols-3 xl:grid-cols-5"
  aria-label={t.admin.stats.total}
>
  {#each metrics as metric (metric)}
    <div class="bg-muted/40 rounded-lg border p-3">
      <dt class="text-muted-foreground">{t.admin.stats[metric]}</dt>
      <dd class="mt-2 text-2xl font-semibold tabular-nums">{stats[metric]}</dd>
    </div>
  {/each}
  <div class="bg-muted/40 rounded-lg border p-3">
    <dt class="text-muted-foreground">{t.admin.stats.conversion}</dt>
    <dd class="mt-2 text-2xl font-semibold tabular-nums">{percent(conversion)}</dd>
  </div>
</dl>
{#if !hasEvents}
  <p class="rounded-lg border p-5">{ui.empty}</p>
{:else}
  <figure class="mb-5 min-w-0 rounded-lg border p-3">
    <figcaption class="mb-3 font-medium">{ui.chart}</figcaption>
    <svg viewBox="0 0 600 180" class="h-48 w-full" aria-hidden="true">
      {#each metrics as metric, index (metric)}
        <polyline
          fill="none"
          stroke={colors[index]}
          stroke-width="2.5"
          stroke-dasharray={index ? `${index * 3} 3` : undefined}
          points={stats.days
            .map(
              (d, i) =>
                `${20 + (i * 560) / Math.max(1, stats.days.length - 1)},${160 - (d[metric] / max) * 140}`,
            )
            .join(' ')}
        />
        {#each stats.days as d, i (d.date)}<circle
            cx={20 + (i * 560) / Math.max(1, stats.days.length - 1)}
            cy={160 - (d[metric] / max) * 140}
            r="3"
            fill={colors[index]}
          />{/each}
      {/each}
    </svg>
    <ul class="flex flex-wrap gap-4 text-sm">
      {#each metrics as metric, index (metric)}<li class="flex items-center gap-2">
          <svg width="24" height="8" aria-hidden="true"
            ><line
              x1="0"
              y1="4"
              x2="24"
              y2="4"
              stroke={colors[index]}
              stroke-width="3"
              stroke-dasharray={index ? `${index * 3} 3` : undefined}
            /></svg
          >{t.admin.stats[metric]}
        </li>{/each}
    </ul>
  </figure>
  <details open>
    <summary class="min-h-11 cursor-pointer py-3 font-medium">{ui.table}</summary>
    <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
    <div class="max-w-full overflow-x-auto" role="region" aria-label={ui.table} tabindex="0">
      <table class="w-full text-sm">
        <caption class="sr-only">{t.admin.stats.title}</caption>
        <thead>
          <tr>
            <th scope="col" class="pr-3 text-left">{t.admin.stats.date}</th>
            {#each metrics as metric (metric)}
              <th scope="col" class="px-2 text-right">{t.admin.stats[metric]}</th>
            {/each}
            <th scope="col" class="pl-3 text-right">{t.admin.stats.conversion}</th>
          </tr>
        </thead>
        <tbody>
          {#each stats.days as d (d.date)}
            <tr>
              <th scope="row" class="py-1 pr-3 text-left font-normal">{d.date}</th>
              {#each metrics as metric (metric)}
                <td class="min-w-20 px-2 text-right tabular-nums">
                  <span>{d[metric]}</span>
                  <div class="bg-muted mt-1 h-2 w-full" aria-hidden="true">
                    <div
                      class="bg-primary h-2 rounded-sm"
                      style={`width: ${(d[metric] / max) * 100}%`}
                    ></div>
                  </div>
                </td>
              {/each}
              <td class="pl-3 text-right tabular-nums"
                >{percent(d.visits === 0 ? null : d.submits / d.visits)}</td
              >
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  </details>
{/if}
<p class="text-muted-foreground text-xs">{t.admin.stats.hint}</p>

<p class="text-muted-foreground mt-3 text-xs">{ui.explanation}</p>
{#if stats.visits === 0}<p class="text-muted-foreground mt-3 text-sm">{ui.instrumentation}</p>{/if}
