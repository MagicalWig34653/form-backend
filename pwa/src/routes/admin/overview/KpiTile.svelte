<script lang="ts" module>
  export interface TileDelta {
    direction: 'up' | 'down' | 'flat';
    /** Complete text, e.g. "+14 ggü. Vorwoche"; meaning never relies on color alone. */
    text: string;
  }
</script>

<script lang="ts">
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import CountUp from './CountUp.svelte';
  import Sparkline from './Sparkline.svelte';

  /**
   * Reusable KPI tile (also used by step 3). Never shows an invented zero: `unavailable`
   * and `value === null` render a dash plus an explanation.
   */
  interface Props {
    label: string;
    /** Short explanation behind the info symbol (also read by screen readers). */
    hint?: string;
    status?: 'loading' | 'ready' | 'unavailable';
    value?: number | null;
    format?: (n: number) => string;
    /** Daily values for the sparkline, oldest first; null entries are gaps. Omit for tiles without a trend; null = trend unknown. */
    series?: (number | null)[] | null;
    /** Accessible description of the series including its values. */
    seriesLabel?: string;
    delta?: TileDelta | null;
    /** Share (0..1) drawn as a bar where other tiles show a trend; keeps all tiles equally tall. */
    fraction?: number;
    /** Extra line under the value, e.g. scope or "of N". */
    note?: string;
    /** Explanation for the dash when no value can be shown. */
    reason?: string;
    /** Index for the staggered entrance (max 8 steps). */
    index?: number;
    class?: string;
  }
  let {
    label,
    hint,
    status = 'ready',
    value = null,
    format,
    series = undefined,
    seriesLabel = '',
    delta = null,
    note,
    fraction,
    reason,
    index = 0,
    class: className,
  }: Props = $props();
  const arrows = { up: '▲', down: '▼', flat: '–' } as const;
  const hasSeries = $derived(!!series && series.filter((v) => v !== null).length >= 2);
</script>

<div
  data-slot="card"
  class={cn(
    'bg-card ring-1 ring-foreground/10 rounded-xl h-full min-w-0 flex-col gap-2 p-5 flex',
    className,
  )}
  style={`--i:${Math.min(index, 7)}`}
  aria-busy={status === 'loading'}
  data-status={status}
  role="group"
  aria-label={label}
>
  <div class="text-muted-foreground flex items-start gap-1.5 text-sm">
    <span class="text-foreground text-base font-medium">{label}</span>
    {#if hint}<button
        type="button"
        aria-label={hint}
        title={hint}
        class="inline-flex size-6 items-center justify-center rounded-full [&>svg]:size-3.5"
        ><NavIcon name="info" size={14} /></button
      >{/if}
  </div>
  {#if status === 'loading'}
    <Skeleton class="h-9 w-24" />
    <Skeleton class="h-10 w-full" />
    <Skeleton class="h-4 w-32" />
    <span class="sr-only">{t.overview.loadingMetric}</span>
  {:else if status === 'unavailable' || value === null}
    <p class="text-[32px] leading-9 font-semibold">
      <span aria-hidden="true">–</span><span class="sr-only">{t.overview.noData}</span>
    </p>
    <p class="text-muted-foreground text-sm">
      {reason ?? (status === 'unavailable' ? t.overview.unavailableReason : t.overview.noData)}
    </p>
  {:else}
    <p class="text-[32px] leading-9 font-semibold tracking-tight tabular-nums">
      <CountUp {value} {...format ? { format } : {}} />
    </p>
    {#if fraction !== undefined}
      <div
        role="img"
        aria-label={note ?? label}
        class="bg-muted my-2 h-2 w-full overflow-hidden rounded-full"
      >
        <div
          class="bg-primary h-full rounded-full"
          style={`width:${Math.round(Math.min(1, Math.max(0, fraction)) * 100)}%`}
        ></div>
      </div>
    {:else if series === undefined}
      <!-- no trend for this metric -->
    {:else if hasSeries && series}<Sparkline values={series} label={seriesLabel || label} />
    {:else}<span class="sr-only">{t.overview.sparkNone}</span>
      <div aria-hidden="true" class="my-1 h-10"></div>{/if}
    {#if delta}<p class="text-sm font-medium" data-direction={delta.direction}>
        <span aria-hidden="true" class="mr-1 text-[0.7em]">{arrows[delta.direction]}</span
        >{delta.text}
      </p>{/if}
  {/if}
  {#if note && status !== 'loading'}<p class="text-muted-foreground text-sm">
      {note}
    </p>{/if}
</div>
