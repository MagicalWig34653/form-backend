<script lang="ts">
  import { cn } from '$lib/utils';

  interface Props {
    label: string;
    /** Already formatted value; use "—" when undefined, never an invented zero. */
    value: string;
    hint?: string;
    /** Optional per-day series for a decorative sparkline (the table carries the real values). */
    series?: number[];
    class?: string;
  }
  let { label, value, hint, series, class: className }: Props = $props();

  const W = 120;
  const H = 28;
  const geometry = $derived.by(() => {
    if (!series || series.length < 2) return null;
    const max = Math.max(1, ...series);
    const points = series.map((v, i): [number, number] => [
      (i * W) / (series.length - 1),
      H - 3 - (v / max) * (H - 8),
    ]);
    const line = points.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`);
    return { line: line.join(' '), area: `${line.join(' ')} L${W} ${H} L0 ${H} Z` };
  });
</script>

<div class={cn('surface-card flex min-w-0 flex-col gap-0.5 px-4 py-3.5', className)}>
  <dt class="text-muted-foreground text-[length:var(--fs-small)] leading-[18px]">{label}</dt>
  <dd class="m-0 text-[length:var(--fs-display)] leading-9 font-[650] tracking-tight tabular-nums">
    {value}
  </dd>
  {#if hint}<dd class="text-muted-foreground m-0 text-[length:var(--fs-small)] leading-[18px]">
      {hint}
    </dd>{/if}
  {#if geometry}
    <svg
      viewBox={`0 0 ${W} ${H}`}
      class="mt-1.5 h-7 w-full"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <path d={geometry.area} fill="color-mix(in srgb, var(--ui-accent) 12%, transparent)" />
      <path
        d={geometry.line}
        fill="none"
        stroke="var(--ui-accent)"
        stroke-width="1.75"
        stroke-linejoin="round"
        stroke-linecap="round"
        vector-effect="non-scaling-stroke"
      />
    </svg>
  {/if}
</div>
