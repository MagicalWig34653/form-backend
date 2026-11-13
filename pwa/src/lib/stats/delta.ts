import { t } from '$lib/i18n';
import type { TileDelta } from '../../routes/admin/overview/KpiTile.svelte';

type Pair = { current: number; previous: number } | null;

const signed = new Intl.NumberFormat('de-DE', {
  signDisplay: 'exceptZero',
  maximumFractionDigits: 0,
});
const points = new Intl.NumberFormat('de-DE', {
  signDisplay: 'exceptZero',
  maximumFractionDigits: 1,
});

/** Percent text for a quota (0.25 -> "25 %"). */
export const formatPercent = (n: number): string =>
  new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 }).format(n);

/** Week-over-week difference of a count, e.g. "+14 ggü. Vorwoche". */
export function countDelta(pair: Pair): TileDelta | null {
  if (!pair) return null;
  const d = pair.current - pair.previous;
  return d === 0
    ? { direction: 'flat', text: t.overview.unchanged }
    : { direction: d > 0 ? 'up' : 'down', text: `${signed.format(d)} ${t.overview.vsWeek}` };
}

/** Week-over-week difference of a quota in percentage points. */
export function pointsDelta(pair: Pair): TileDelta | null {
  if (!pair) return null;
  const d = Math.round((pair.current - pair.previous) * 1000) / 10;
  return d === 0
    ? { direction: 'flat', text: t.overview.unchanged }
    : { direction: d > 0 ? 'up' : 'down', text: `${points.format(d)} ${t.overview.vsWeekPoints}` };
}
