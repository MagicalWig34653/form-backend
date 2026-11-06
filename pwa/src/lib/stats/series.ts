import type { Statistics } from '$lib/api/admin';

/** A daily series, oldest first. `null` = unknown (no server confirmation), never an invented zero. */
export type Series = (number | null)[];
export type Metric = 'visits' | 'begins' | 'submits' | 'abandons';

const DAY = 86_400_000;
const parse = (iso: string): number => Date.parse(`${iso}T00:00:00Z`);
const format = (ms: number): string => new Date(ms).toISOString().slice(0, 10);

/**
 * The last `count` days ending at `stats.to`. Days inside the period the server confirmed (from..to)
 * that have no row are real zeros; days outside it stay null.
 */
export function dailySeries(stats: Statistics, metric: Metric, count = 14): Series {
  const to = parse(stats.to);
  const from = parse(stats.from);
  if (Number.isNaN(to) || Number.isNaN(from)) return Array<null>(count).fill(null);
  const byDate = new Map(stats.days.map((d) => [d.date, d[metric]]));
  return Array.from({ length: count }, (_, i) => {
    const ms = to - (count - 1 - i) * DAY;
    if (ms < from || ms > to) return null;
    return byDate.get(format(ms)) ?? 0;
  });
}

/** Element-wise sum; an index is null only when no series knows it. */
export function sumSeries(list: Series[], count = 14): Series {
  return Array.from({ length: count }, (_, i) => {
    let known = false;
    let sum = 0;
    for (const s of list) {
      const v = s[i];
      if (v !== null && v !== undefined) {
        known = true;
        sum += v;
      }
    }
    return known ? sum : null;
  });
}

/** Sum of known values, or null when nothing is known. */
export function total(series: Series): number | null {
  const known = series.filter((v): v is number => v !== null);
  return known.length === 0 ? null : known.reduce((a, b) => a + b, 0);
}

/** Last 7 days against the 7 days before; null unless both weeks are fully known. */
export function weekOverWeek(series: Series): { current: number; previous: number } | null {
  if (series.length < 14) return null;
  const cur = series.slice(-7);
  const prev = series.slice(-14, -7);
  if ([...cur, ...prev].some((v) => v === null)) return null;
  const sum = (a: Series) => a.reduce<number>((s, v) => s + (v ?? 0), 0);
  return { current: sum(cur), previous: sum(prev) };
}

/** Conversion = submits / visits; null (undefined) without visits. */
export function conversion(visits: number | null, submits: number | null): number | null {
  if (visits === null || submits === null || visits <= 0) return null;
  return submits / visits;
}

/** Per-day conversion series; null where visits or submits are unknown or visits are zero. */
export function conversionSeries(visits: Series, submits: Series): Series {
  return visits.map((v, i) => conversion(v, submits[i] ?? null));
}

/** Conversion of the last week and the week before (null when undefined). */
export function conversionWeeks(
  visits: Series,
  submits: Series,
): { current: number; previous: number } | null {
  const v = weekOverWeek(visits);
  const s = weekOverWeek(submits);
  if (!v || !s) return null;
  const current = conversion(v.current, s.current);
  const previous = conversion(v.previous, s.previous);
  return current === null || previous === null ? null : { current, previous };
}

/**
 * Run `fn` over `items` with at most `limit` in flight. Results keep the input order;
 * `fn` must not throw (wrap errors into the result).
 */
export async function mapLimited<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T, index: number) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array<R>(items.length);
  let next = 0;
  const worker = async (): Promise<void> => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index] as T, index);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

const rtf = new Intl.RelativeTimeFormat('de', { numeric: 'auto' });
/** "vor 12 Minuten", "gestern", else a short date. Null for missing or invalid input. */
export function relativeTime(iso: string | null, now: number = Date.now()): string | null {
  if (!iso) return null;
  const ms = Date.parse(iso);
  if (Number.isNaN(ms)) return null;
  const diff = (ms - now) / 1000;
  const abs = Math.abs(diff);
  if (abs < 60) return rtf.format(Math.round(diff), 'second');
  if (abs < 3600) return rtf.format(Math.round(diff / 60), 'minute');
  if (abs < 86_400) return rtf.format(Math.round(diff / 3600), 'hour');
  if (abs < 7 * 86_400) return rtf.format(Math.round(diff / 86_400), 'day');
  return new Intl.DateTimeFormat('de-DE', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
  }).format(ms);
}
