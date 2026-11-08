<script lang="ts" module>
  export interface Geometry {
    lines: string[];
    areas: string[];
    dots: { x: number; y: number }[];
    end: { x: number; y: number } | null;
  }

  /** Pure geometry: runs of known values become lines and areas, null breaks the line (a gap). */
  export function geometry(
    values: (number | null)[],
    width: number,
    height: number,
    pad = 3,
  ): Geometry {
    const known = values.filter((v): v is number => v !== null);
    const out: Geometry = { lines: [], areas: [], dots: [], end: null };
    if (known.length === 0) return out;
    const max = Math.max(...known, 1);
    const stepX = values.length > 1 ? (width - pad * 2) / (values.length - 1) : 0;
    const point = (v: number, i: number) => ({
      x: +(pad + i * stepX).toFixed(2),
      y: +(height - pad - (v / max) * (height - pad * 2)).toFixed(2),
    });
    let run: { x: number; y: number }[] = [];
    const flush = (): void => {
      if (run.length === 1) out.dots.push(run[0]!);
      if (run.length > 1) {
        const line = run.map((p, i) => `${i === 0 ? 'M' : 'L'}${p.x} ${p.y}`).join(' ');
        out.lines.push(line);
        const first = run[0]!;
        const last = run[run.length - 1]!;
        out.areas.push(`${line} L${last.x} ${height - pad} L${first.x} ${height - pad} Z`);
      }
      run = [];
    };
    values.forEach((v, i) => {
      if (v === null) flush();
      else {
        const p = point(v, i);
        run.push(p);
        out.end = p;
      }
    });
    flush();
    return out;
  }
</script>

<script lang="ts">
  import { cn } from '$lib/utils';

  interface Props {
    values: (number | null)[];
    /** Full accessible description, including the values (the SVG is the only text alternative). */
    label: string;
    width?: number;
    height?: number;
    class?: string;
  }
  let { values, label, width = 160, height = 40, class: className }: Props = $props();
  const g = $derived(geometry(values, width, height));
</script>

<svg
  role="img"
  aria-label={label}
  viewBox={`0 0 ${width} ${height}`}
  class={cn('text-brand-ink block h-auto max-h-14 w-full overflow-visible', className)}
  data-testid="sparkline"
>
  {#each g.areas as d, i (i)}<path
      {d}
      fill="currentColor"
      fill-opacity="0.12"
      stroke="none"
    />{/each}
  {#each g.lines as d, i (i)}<path
      {d}
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    />{/each}
  {#each g.dots as p, i (i)}<circle cx={p.x} cy={p.y} r="2.5" fill="currentColor" />{/each}
  {#if g.end}<circle
      cx={g.end.x}
      cy={g.end.y}
      r="3"
      fill="currentColor"
      stroke="var(--background)"
      stroke-width="1.5"
      data-testid="sparkline-end"
    />{/if}
</svg>
