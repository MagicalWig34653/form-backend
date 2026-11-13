/** Shared German date and time formatting. Never returns "undefined" or "Invalid Date". */

/** Shown wherever a date or time is missing or cannot be read. */
export const NO_VALUE = '–';

interface Options {
  /** Render in UTC instead of the browser's time zone. */
  utc?: boolean;
}

const cache = new Map<string, Intl.DateTimeFormat>();
function formatter(key: string, options: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  let f = cache.get(key);
  if (!f) {
    f = new Intl.DateTimeFormat('de-DE', options);
    cache.set(key, f);
  }
  return f;
}

/** Date-only ISO strings (JJJJ-MM-TT) are calendar days and must not shift with the time zone. */
const DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

function toMs(value: string | number | null | undefined): number | null {
  if (value === null || value === undefined || value === '') return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const day = DAY.exec(value);
  const ms = day ? Date.UTC(Number(day[1]), Number(day[2]) - 1, Number(day[3])) : Date.parse(value);
  return Number.isNaN(ms) ? null : ms;
}
const zone = (o?: Options, value?: string | number | null): 'UTC' | undefined =>
  o?.utc || (typeof value === 'string' && DAY.test(value)) ? 'UTC' : undefined;

/** "03.11.2026" */
export function formatDay(value: string | number | null | undefined, o?: Options): string {
  const ms = toMs(value);
  if (ms === null) return NO_VALUE;
  const timeZone = zone(o, value);
  return formatter(`d|${timeZone}`, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    ...(timeZone ? { timeZone } : {}),
  }).format(ms);
}

/** "03.11." for chart axes. */
export function formatDayShort(value: string | null | undefined): string {
  const ms = toMs(value);
  if (ms === null) return NO_VALUE;
  return shortDay(ms);
}
function shortDay(ms: number): string {
  return formatter('s|UTC', { day: '2-digit', month: '2-digit', timeZone: 'UTC' }).format(ms);
}

/** "03.11.2026, 10:00" */
export function formatDateTime(value: string | number | null | undefined, o?: Options): string {
  const ms = toMs(value);
  if (ms === null) return NO_VALUE;
  const timeZone = zone(o, value);
  return formatter(`dt|${timeZone}`, {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23',
    ...(timeZone ? { timeZone } : {}),
  }).format(ms);
}

/** "Gespeichert · 10:00" status text after a save; the label comes from the caller. */
export function stamped(label: string, at: Date = new Date()): string {
  return `${label} · ${formatClock(at)}`;
}

/** "10:00" */
export function formatClock(value: string | number | Date | null | undefined): string {
  const ms = value instanceof Date ? value.getTime() : toMs(value);
  if (ms === null || Number.isNaN(ms)) return NO_VALUE;
  return formatter('t|', { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(ms);
}

/** "03.10.–01.11.2026" (same year), "28.12.2025–03.01.2026" (different years). */
export function formatPeriod(
  from: string | null | undefined,
  to: string | null | undefined,
): string {
  const a = toMs(from);
  const b = toMs(to);
  if (a === null || b === null) return NO_VALUE;
  const full = (ms: number): string => formatDay(ms, { utc: true });
  const year = (ms: number): number => new Date(ms).getUTCFullYear();
  if (year(a) !== year(b)) return `${full(a)}–${full(b)}`;
  return `${shortDay(a)}–${full(b)}`;
}
