<script lang="ts">
  import { t } from '$lib/i18n';
  import type { Statistics } from '$lib/api/admin';
  import StatTile from './StatTile.svelte';

  let { stats, days }: { stats: Statistics; days: number } = $props();
  const ui = t.admin.statisticsPage;
  const metrics = ['visits', 'begins', 'submits', 'abandons'] as const;
  type Metric = (typeof metrics)[number];
  const conversion = $derived(stats.visits === 0 ? null : stats.submits / stats.visits);
  const hasEvents = $derived(metrics.some((metric) => stats[metric] > 0));
  const percent = (value: number | null): string =>
    value === null
      ? '—'
      : new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 }).format(
          value,
        );

  // Series differ by colour, dash pattern and direct label, never by colour alone.
  const style: Record<Metric, { color: string; dash: string | undefined }> = {
    visits: { color: 'var(--ui-accent)', dash: undefined },
    begins: { color: 'var(--muted-foreground)', dash: '6 4' },
    submits: { color: 'var(--chart-3)', dash: undefined },
    abandons: { color: 'var(--chart-4)', dash: '2 3' },
  };

  // SVG text must stay readable: on narrow screens the drawing is as wide as the card.
  let viewport = $state(1024);
  const W = $derived(viewport < 640 ? Math.max(260, viewport - 72) : 640);
  const H = 220;
  const direct = $derived(W >= 480);
  const padL = 34;
  const padR = $derived(direct ? 104 : 12);
  const padT = 14;
  const padB = 28;
  const plotW = $derived(W - padL - padR);
  const plotH = H - padT - padB;
  const few = $derived(stats.days.length <= 7);

  const top = $derived.by(() => {
    const max = Math.max(1, ...stats.days.flatMap((d) => metrics.map((m) => d[m])));
    const magnitude = 10 ** Math.floor(Math.log10(max));
    const step = [1, 2, 5, 10].find((k) => k * magnitude >= max) ?? 10;
    return step * magnitude;
  });
  const y = (value: number): number => padT + plotH - (value / top) * plotH;
  const ticks = $derived(Number.isInteger(top / 2) && top > 2 ? [0, top / 2, top] : [0, top]);
  const x = (i: number): number =>
    padL + (stats.days.length < 2 ? plotW / 2 : (i * plotW) / (stats.days.length - 1));
  const shortDate = (iso: string): string => `${iso.slice(8, 10)}.${iso.slice(5, 7)}.`;

  const lines = $derived(
    metrics.map((metric) => ({
      metric,
      points: stats.days.map((d, i) => `${x(i).toFixed(1)},${y(d[metric]).toFixed(1)}`).join(' '),
    })),
  );
  const area = $derived(
    stats.days.length < 2
      ? ''
      : `M${x(0)},${y(0)} ` +
          stats.days.map((d, i) => `L${x(i).toFixed(1)},${y(d.visits).toFixed(1)}`).join(' ') +
          ` L${x(stats.days.length - 1)},${y(0)} Z`,
  );
  // End-of-line labels, pushed apart so that they never overlap.
  const labels = $derived.by(() => {
    const last = stats.days[stats.days.length - 1];
    if (!last) return [];
    const items = metrics
      .map((metric) => ({ metric, value: last[metric], y: y(last[metric]) }))
      .sort((a, b) => a.y - b.y);
    for (let i = 1; i < items.length; i++)
      items[i]!.y = Math.max(items[i]!.y, items[i - 1]!.y + 15);
    return items;
  });

  // Few days: grouped bars read better than two diagonals.
  const groupW = $derived(plotW / Math.max(1, stats.days.length));
  const barW = $derived(Math.min(20, (groupW * 0.8) / metrics.length));
</script>

<header class="mb-4 flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
  <div>
    <h2 class="text-[17px] leading-[26px] font-semibold tracking-tight">
      {ui.title}
    </h2>
    <p class="text-muted-foreground text-sm leading-[18px]">
      {t.admin.stats.range.replace('{n}', String(days))} ·
      {ui.period.replace('{from}', stats.from).replace('{to}', stats.to)}
    </p>
  </div>
  <span
    class="bg-muted text-muted-foreground rounded-full px-2.5 py-0.5 text-sm leading-[18px] font-medium"
    >{ui.scope}</span
  >
</header>
<svelte:window bind:innerWidth={viewport} />
<dl
  class="mb-5 grid grid-cols-[repeat(auto-fit,minmax(9.5rem,1fr))] gap-3"
  aria-label={t.admin.stats.total}
>
  {#each metrics as metric (metric)}
    <StatTile
      label={t.admin.stats[metric]}
      icon={metric}
      value={String(stats[metric])}
      series={stats.days.length > 2 ? stats.days.map((d) => d[metric]) : undefined}
    />
  {/each}
  <StatTile label={t.admin.stats.conversion} icon="conversion" value={percent(conversion)} />
</dl>
{#if !hasEvents}
  <p class="bg-muted/60 text-muted-foreground rounded-xl p-5 text-center">
    {ui.empty}
  </p>
{:else}
  <section class="bg-card ring-1 ring-foreground/10 rounded-xl mb-4 min-w-0 px-5 py-4">
    <figure class="mb-3 min-w-0">
      <figcaption class="mb-2 font-medium">{ui.chart}</figcaption>
      <svg viewBox={`0 0 ${W} ${H}`} class="block h-auto w-full" aria-hidden="true">
        {#each ticks as tick (tick)}
          <line
            x1={padL}
            x2={W - padR}
            y1={y(tick)}
            y2={y(tick)}
            stroke="var(--border-border)"
            stroke-width="1"
          />
          <text
            x={padL - 6}
            y={y(tick) + 4}
            text-anchor="end"
            font-size="11"
            fill="var(--muted-foreground)">{tick}</text
          >
        {/each}
        {#if few}
          {#each stats.days as d, i (d.date)}
            {@const gx = padL + i * groupW + (groupW - barW * metrics.length) / 2}
            {#each metrics as metric, k (metric)}
              {@const bx = gx + k * barW}
              <rect
                x={bx + 1}
                y={y(d[metric])}
                width={Math.max(1, barW - 2)}
                height={Math.max(0, y(0) - y(d[metric]))}
                rx="2"
                fill={style[metric].color}
              />
              <text
                x={bx + barW / 2}
                y={y(d[metric]) - 4}
                text-anchor="middle"
                font-size="10"
                fill="var(--foreground)">{d[metric]}</text
              >
            {/each}
            <text
              x={padL + i * groupW + groupW / 2}
              y={H - 8}
              text-anchor="middle"
              font-size="11"
              fill="var(--muted-foreground)">{shortDate(d.date)}</text
            >
          {/each}
        {:else}
          {#if area}<path
              d={area}
              fill="color-mix(in srgb, var(--ui-accent) 10%, transparent)"
            />{/if}
          {#each lines as line (line.metric)}
            <polyline
              fill="none"
              stroke={style[line.metric].color}
              stroke-width="2.25"
              stroke-linejoin="round"
              stroke-linecap="round"
              stroke-dasharray={style[line.metric].dash}
              points={line.points}
            />
          {/each}
          {#each lines as line (line.metric)}
            {@const last = stats.days[stats.days.length - 1]}
            {#if last}<circle
                cx={x(stats.days.length - 1)}
                cy={y(last[line.metric])}
                r="3.5"
                fill={style[line.metric].color}
              />{/if}
          {/each}
          <text x={padL} y={H - 8} font-size="11" fill="var(--muted-foreground)"
            >{shortDate(stats.days[0]?.date ?? '')}</text
          >
          <text
            x={W - padR}
            y={H - 8}
            text-anchor="end"
            font-size="11"
            fill="var(--muted-foreground)"
            >{shortDate(stats.days[stats.days.length - 1]?.date ?? '')}</text
          >
          {#if direct}
            {#each labels as item (item.metric)}
              <line
                x1={W - padR + 10}
                x2={W - padR + 24}
                y1={item.y}
                y2={item.y}
                stroke={style[item.metric].color}
                stroke-width="2.5"
                stroke-dasharray={style[item.metric].dash}
              />
              <text x={W - padR + 29} y={item.y + 4} font-size="12" fill="var(--foreground)"
                >{t.admin.stats[item.metric]} {item.value}</text
              >
            {/each}
          {/if}
        {/if}
      </svg>
      {#if !direct || few}
        <ul class="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-sm">
          {#each metrics as metric (metric)}<li class="flex items-center gap-2">
              <svg width="22" height="8" aria-hidden="true"
                ><line
                  x1="0"
                  y1="4"
                  x2="22"
                  y2="4"
                  stroke={style[metric].color}
                  stroke-width="3"
                  stroke-dasharray={few ? undefined : style[metric].dash}
                /></svg
              >{t.admin.stats[metric]}
            </li>{/each}
        </ul>
      {/if}
    </figure>
    <details open class="group">
      <summary class="focus-visible:outline-ring min-h-11 cursor-pointer py-3 font-medium"
        >{ui.table}</summary
      >
      <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
      <div
        class="border-border max-w-full overflow-x-auto rounded-lg border"
        role="region"
        aria-label={ui.table}
        tabindex="0"
      >
        <table class="w-full text-sm">
          <caption class="sr-only">{t.admin.stats.title}</caption>
          <thead class="bg-muted/60 text-muted-foreground">
            <tr>
              <th scope="col" class="px-3 py-2 text-left font-medium whitespace-nowrap"
                >{t.admin.stats.date}</th
              >
              {#each metrics as metric (metric)}
                <th scope="col" class="px-3 py-2 text-right font-medium">{t.admin.stats[metric]}</th
                >
              {/each}
              <th scope="col" class="px-3 py-2 text-right font-medium"
                >{t.admin.stats.conversion}</th
              >
            </tr>
          </thead>
          <tbody class="divide-border divide-y">
            {#each stats.days as d (d.date)}
              <tr class="hover:bg-muted/50">
                <th scope="row" class="px-3 py-1.5 text-left font-normal whitespace-nowrap"
                  >{d.date}</th
                >
                {#each metrics as metric (metric)}
                  <td class="px-3 py-1.5 text-right tabular-nums">{d[metric]}</td>
                {/each}
                <td class="px-3 py-1.5 text-right tabular-nums"
                  >{percent(d.visits === 0 ? null : d.submits / d.visits)}</td
                >
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </details>
  </section>
{/if}
<p class="text-muted-foreground mt-3 text-sm">{t.admin.stats.hint}</p>

<p class="text-muted-foreground mt-2 text-sm">{ui.explanation}</p>
{#if stats.visits === 0}<p class="text-muted-foreground mt-2 text-sm">
    {ui.instrumentation}
  </p>{/if}
