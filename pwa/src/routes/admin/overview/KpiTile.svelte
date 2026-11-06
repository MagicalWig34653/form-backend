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
    reason,
    index = 0,
    class: className,
  }: Props = $props();
  const arrows = { up: '▲', down: '▼', flat: '–' } as const;
  const hasSeries = $derived(!!series && series.some((v) => v !== null));
</script>

<div
  class={cn('surface-card ov-rise flex min-w-0 flex-col gap-2 p-4', className)}
  style={`--i:${Math.min(index, 7)}`}
  aria-busy={status === 'loading'}
  data-status={status}
  role="group"
  aria-label={label}
>
  <div class="text-muted-foreground flex items-center gap-1.5 text-[length:var(--fs-small)]">
    <span class="font-medium">{label}</span>
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
    <p
      class="text-[length:var(--fs-display)] leading-9 font-semibold"
      aria-label={t.overview.noData}
    >
      <span aria-hidden="true">–</span>
    </p>
    <p class="text-muted-foreground text-[length:var(--fs-small)]">
      {reason ?? (status === 'unavailable' ? t.overview.unavailableReason : t.overview.noData)}
    </p>
  {:else}
    <p class="text-[length:var(--fs-display)] leading-9 font-semibold tracking-tight tabular-nums">
      <CountUp {value} {...format ? { format } : {}} />
    </p>
    {#if series === undefined}
      <!-- no trend for this metric -->
    {:else if hasSeries && series}<Sparkline values={series} label={seriesLabel || label} />
    {:else}<p class="text-muted-foreground text-[length:var(--fs-small)]">
        {t.overview.sparkNone}
      </p>{/if}
    {#if delta}<p
        class="text-[length:var(--fs-small)] font-medium"
        data-direction={delta.direction}
      >
        <span aria-hidden="true" class="mr-1 text-[0.7em]">{arrows[delta.direction]}</span
        >{delta.text}
      </p>{/if}
  {/if}
  {#if note && status !== 'loading'}<p class="text-muted-foreground text-[length:var(--fs-small)]">
      {note}
    </p>{/if}
</div>

<style>
  /* Rise without fading: opacity changes would lower the measured text contrast mid-animation. */
  @keyframes ov-rise {
    from {
      transform: translateY(8px);
    }
    to {
      transform: none;
    }
  }
  :global(.ov-rise) {
    animation: ov-rise var(--dur-slow) var(--ease-out) both;
    animation-delay: calc(var(--i, 0) * 40ms);
  }
  :global(html[data-effects='off'] .ov-rise) {
    animation: none;
  }
</style>
