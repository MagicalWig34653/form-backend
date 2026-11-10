<script lang="ts">
  import { formatDay, formatDayShort } from '$lib/format';
  import { scrollHint } from '$lib/scrollHint';
  import { t } from '$lib/i18n';
  import type { Statistics } from '$lib/api/admin';
  import { denseDays } from '$lib/stats/series';

  let { stats: source }: { stats: Statistics } = $props();
  const stats = $derived({ ...source, days: denseDays(source) });
  const ui = t.admin.statisticsPage;
  const metrics = ['visits', 'begins', 'submits', 'abandons'] as const;
  type Metric = (typeof metrics)[number];
  const hasEvents = $derived(metrics.some((metric) => stats[metric] > 0));
  const percent = (value: number | null): string =>
    value === null
      ? '—'
      : new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 }).format(
          value,
        );

  // Series differ by colour, dash pattern and direct label, never by colour alone.
  type Shape = 'circle' | 'square' | 'diamond' | 'triangle';
  const style: Record<Metric, { color: string; dash: string | undefined; shape: Shape }> = {
    visits: { color: 'var(--chart-1)', dash: undefined, shape: 'circle' },
    begins: { color: 'var(--muted-foreground)', dash: '6 4', shape: 'square' },
    submits: { color: 'var(--ui-accent)', dash: undefined, shape: 'diamond' },
    abandons: { color: 'var(--chart-4)', dash: '2 3', shape: 'triangle' },
  };
  /** Marker outline (centre cx, cy; half-size r) for the series shapes: colour is never the only cue. */
  function marker(shape: Shape, cx: number, cy: number, r = 4): string {
    if (shape === 'square') return `M${cx - r},${cy - r}h${2 * r}v${2 * r}h${-2 * r}z`;
    if (shape === 'diamond')
      return `M${cx},${cy - r - 1}L${cx + r + 1},${cy}L${cx},${cy + r + 1}L${cx - r - 1},${cy}z`;
    if (shape === 'triangle')
      return `M${cx},${cy - r - 1}L${cx + r + 1},${cy + r}L${cx - r - 1},${cy + r}z`;
    return `M${cx - r},${cy}a${r},${r} 0 1,0 ${2 * r},0a${r},${r} 0 1,0 ${-2 * r},0z`;
  }
  const barFill = (metric: Metric): string =>
    metric === 'begins'
      ? 'url(#stat-hatch)'
      : metric === 'abandons'
        ? 'url(#stat-dots)'
        : style[metric].color;

  // SVG text must stay readable: on narrow screens the drawing is as wide as the card.
  let boxWidth = $state(0);
  const W = $derived(boxWidth > 0 ? Math.min(1100, Math.max(260, Math.round(boxWidth))) : 640);
  const H = 220;
  const padL = 34;
  const padR = 14;
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
  /** Indices of the dates under the axis: first, last and evenly spaced ones between them. */
  const dateTicks = $derived.by(() => {
    const n = stats.days.length;
    if (n < 2) return n === 1 ? [0] : [];
    const count = Math.min(n, W < 420 ? 3 : W < 700 ? 4 : 5);
    return [
      ...new Set(Array.from({ length: count }, (_, k) => Math.round((k * (n - 1)) / (count - 1)))),
    ];
  });
  const shortDate = (iso: string): string => formatDayShort(iso);

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
  // Few days: grouped bars read better than two diagonals.
  const groupW = $derived(plotW / Math.max(1, stats.days.length));
  const barW = $derived(Math.min(20, (groupW * 0.8) / metrics.length));
</script>

{#if !hasEvents}
  <p class="bg-muted/60 text-muted-foreground m-0 rounded-xl p-5 text-center">
    {ui.empty}
  </p>
  <details class="text-muted-foreground mt-1 text-sm">
    <summary class="min-h-8 cursor-pointer py-1 font-medium">{ui.notes}</summary>
    <p class="mt-2">{t.admin.stats.hint}</p>
    <p class="mt-2">{ui.explanation}</p>
  </details>
{:else}
  <section class="bg-card ring-1 ring-foreground/10 rounded-xl mb-4 min-w-0 px-5 py-4">
    <figure class="mb-3 min-w-0" bind:clientWidth={boxWidth}>
      <figcaption class="mb-2 font-medium">{ui.chart}</figcaption>
      <ul class="mb-2 flex flex-wrap gap-x-4 gap-y-1 text-sm" aria-label={ui.legend}>
        {#each metrics as metric (metric)}<li class="flex items-center gap-2">
            <svg width="26" height="12" aria-hidden="true">
              {#if few}
                <rect
                  x="3"
                  y="1"
                  width="20"
                  height="10"
                  rx="2"
                  fill={barFill(metric)}
                  stroke={style[metric].color}
                />
              {:else}
                <line
                  x1="0"
                  y1="6"
                  x2="26"
                  y2="6"
                  stroke={style[metric].color}
                  stroke-width="2.5"
                  stroke-dasharray={style[metric].dash}
                />
                <path d={marker(style[metric].shape, 13, 6, 3.5)} fill={style[metric].color} />
              {/if}
            </svg>{t.admin.stats[metric]}
            <span class="text-muted-foreground tabular-nums">{stats[metric]}</span>
          </li>{/each}
      </ul>
      <svg viewBox={`0 0 ${W} ${H}`} class="block h-auto w-full" aria-hidden="true">
        {#each ticks as tick (tick)}
          <line
            x1={padL}
            x2={W - padR}
            y1={y(tick)}
            y2={y(tick)}
            stroke="var(--border)"
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
        <defs>
          <pattern
            id="stat-hatch"
            width="5"
            height="5"
            patternUnits="userSpaceOnUse"
            patternTransform="rotate(45)"
          >
            <rect width="5" height="5" fill="var(--card)" />
            <rect width="2.2" height="5" fill="var(--muted-foreground)" />
          </pattern>
          <pattern id="stat-dots" width="5" height="5" patternUnits="userSpaceOnUse">
            <rect width="5" height="5" fill="var(--card)" />
            <circle cx="2.5" cy="2.5" r="1.4" fill="var(--chart-4)" />
          </pattern>
        </defs>
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
                fill={barFill(metric)}
                stroke={style[metric].color}
                stroke-width="1"
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
            {#if last}<path
                d={marker(style[line.metric].shape, x(stats.days.length - 1), y(last[line.metric]))}
                fill={style[line.metric].color}
              />{/if}
          {/each}
          {#each dateTicks as i, n (i)}
            <text
              x={x(i)}
              y={H - 8}
              text-anchor={n === 0 ? 'start' : n === dateTicks.length - 1 ? 'end' : 'middle'}
              font-size="11"
              fill="var(--muted-foreground)">{shortDate(stats.days[i]?.date ?? '')}</text
            >
          {/each}
        {/if}
      </svg>
    </figure>
    <details class="group">
      <summary class="focus-visible:outline-ring min-h-11 cursor-pointer py-3 font-medium"
        >{ui.table}</summary
      >
      <!-- svelte-ignore a11y_no_noninteractive_tabindex (keyboard access to horizontal scrolling) -->
      <div
        use:scrollHint
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
                  >{formatDay(d.date)}</th
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
    <details class="text-muted-foreground mt-2 text-sm">
      <summary class="min-h-8 cursor-pointer py-1 font-medium">{ui.notes}</summary>
      <p class="mt-2">{t.admin.stats.hint}</p>
      <p class="mt-2">{ui.explanation}</p>
      {#if stats.visits === 0}<p class="mt-2">{ui.instrumentation}</p>{/if}
    </details>
  </section>
{/if}
