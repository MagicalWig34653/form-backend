import { expect, it, vi } from 'vitest';
import type { FormListItem, Statistics } from '$lib/api/admin';
import {
  conversion,
  conversionWeeks,
  dailySeries,
  mapLimited,
  relativeTime,
  sumSeries,
  total,
  weekOverWeek,
} from './series';
import { combinedStatus, deriveAttention, emptySnapshot, setupSteps } from './overview';
import { OverviewLoader, MAX_PARALLEL } from './loader.svelte';

const day = (date: string, submits: number, visits = 0) => ({
  date,
  count: submits,
  visits,
  begins: 0,
  submits,
  abandons: 0,
  conversion: null,
});
const stats = (over: Partial<Statistics> = {}): Statistics => ({
  from: '2026-10-19',
  to: '2026-11-01',
  total: 0,
  visits: 0,
  begins: 0,
  submits: 0,
  abandons: 0,
  conversion: null,
  days: [],
  ...over,
});

it('fills days inside the confirmed period with zeros and leaves the rest as gaps', () => {
  const s = stats({ from: '2026-10-30', days: [day('2026-11-01', 4), day('2026-10-31', 2)] });
  const series = dailySeries(s, 'submits', 14);
  expect(series).toHaveLength(14);
  expect(series.slice(0, 11).every((v) => v === null)).toBe(true);
  expect(series.slice(11)).toEqual([0, 2, 4]);
});
it('does not invent a series from an invalid period', () => {
  expect(dailySeries(stats({ from: 'x' }), 'submits', 3)).toEqual([null, null, null]);
});
it('sums element-wise and keeps unknown indices unknown', () => {
  expect(
    sumSeries(
      [
        [1, null, 2],
        [3, null, null],
      ],
      3,
    ),
  ).toEqual([4, null, 2]);
  expect(total([null, null])).toBeNull();
  expect(total([1, null, 2])).toBe(3);
});
it('compares weeks only when both weeks are known', () => {
  const full = [...Array<number>(7).fill(1), ...Array<number>(7).fill(3)];
  expect(weekOverWeek(full)).toEqual({ current: 21, previous: 7 });
  expect(weekOverWeek([null, ...full.slice(1)])).toBeNull();
  expect(weekOverWeek([1, 2])).toBeNull();
});
it('leaves conversion undefined without visits', () => {
  expect(conversion(0, 0)).toBeNull();
  expect(conversion(null, 3)).toBeNull();
  expect(conversion(20, 5)).toBe(0.25);
  const v = [...Array<number>(7).fill(0), ...Array<number>(7).fill(10)];
  expect(conversionWeeks(v, v)).toBeNull();
});
it('limits concurrency and keeps result order', async () => {
  let active = 0;
  let peak = 0;
  const out = await mapLimited(
    Array.from({ length: 20 }, (_, i) => i),
    8,
    async (n) => {
      active++;
      peak = Math.max(peak, active);
      await new Promise((r) => setTimeout(r, 1));
      active--;
      return n * 2;
    },
  );
  expect(peak).toBeLessThanOrEqual(8);
  expect(out[19]).toBe(38);
});
it('formats relative time and rejects bad input', () => {
  const now = Date.parse('2026-11-06T12:00:00Z');
  expect(relativeTime('2026-11-06T11:48:00Z', now)).toBe('vor 12 Minuten');
  expect(relativeTime('2026-11-05T11:00:00Z', now)).toBe('gestern');
  expect(relativeTime(null, now)).toBeNull();
  expect(relativeTime('nope', now)).toBeNull();
});
it('combines statuses', () => {
  expect(combinedStatus(['loading', 'error']).status).toBe('loading');
  expect(combinedStatus(['ready', 'error'])).toEqual({ status: 'ready', ready: 1, total: 2 });
  expect(combinedStatus(['error', 'error']).status).toBe('error');
});

const forms: FormListItem[] = [
  { id: 'a', name: 'Kontakt', active: true, currentReleaseId: 'r' },
  { id: 'b', name: 'Anfrage', active: false, currentReleaseId: null },
  { id: 'c', name: 'Stumm', active: true, currentReleaseId: 'r' },
];
it('derives attention hints from metadata', () => {
  const snaps = new Map([
    [
      'a',
      {
        ...emptySnapshot(),
        detailStatus: 'ready' as const,
        detail: {
          id: 'a',
          name: 'Kontakt',
          active: true,
          currentReleaseId: 'r',
          currentReleaseVersion: 1,
          draftIds: [],
          mailConnectionId: null,
        },
      },
    ],
    ['c', { ...emptySnapshot(), statsStatus: 'ready' as const, stats: stats() }],
  ]);
  const kinds = deriveAttention(forms, snaps, true).map((i) => `${i.kind}:${i.formId ?? ''}`);
  expect(kinds).toEqual(['locked:', 'noMail:a', 'unpublished:b', 'quiet:c']);
  expect(deriveAttention(forms, new Map(), false).map((i) => i.kind)).toEqual(['unpublished']);
});
it('computes setup progress and keeps unknown steps unknown', () => {
  const steps = setupSteps(forms, new Map());
  expect(steps.find((s) => s.id === 'form')?.done).toBe(true);
  expect(steps.find((s) => s.id === 'mail')?.done).toBeNull();
  expect(steps.find((s) => s.id === 'published')?.done).toBe(true);
  expect(steps.find((s) => s.id === 'published')?.formId).toBe('b');
});

it('loader fetches per form with at most 8 requests in flight and isolates failures', async () => {
  let active = 0;
  let peak = 0;
  const slow = async <T>(r: T): Promise<T> => {
    active++;
    peak = Math.max(peak, active);
    await new Promise((res) => setTimeout(res, 1));
    active--;
    return r;
  };
  const many: FormListItem[] = Array.from({ length: 12 }, (_, i) => ({
    id: `f${i}`,
    name: `F${i}`,
    active: true,
    currentReleaseId: 'r',
  }));
  const api = {
    statistics: vi.fn((...args: [string, string, number]) =>
      slow(
        args[1] === 'f0'
          ? { ok: false as const, error: { status: 500 } }
          : { ok: true as const, data: stats() },
      ),
    ),
    form: vi.fn(() => slow({ ok: true as const, data: {} })),
    entries: vi.fn(() => slow({ ok: true as const, data: { items: [], nextCursor: null } })),
  };
  const loader = new OverviewLoader(api as never);
  await loader.load('t', many);
  expect(peak).toBeLessThanOrEqual(MAX_PARALLEL);
  expect(api.statistics).toHaveBeenCalledTimes(12);
  expect(api.statistics.mock.calls[0]?.[2]).toBe(14);
  expect(loader.snapshots.get('f0')?.statsStatus).toBe('error');
  expect(loader.snapshots.get('f1')?.statsStatus).toBe('ready');
  expect(loader.snapshots.get('f1')?.entriesStatus).toBe('ready');
});
it('loader turns thrown errors into per-part errors', async () => {
  const api = {
    statistics: vi.fn(() => Promise.reject(new Error('x'))),
    form: vi.fn(),
    entries: vi.fn(),
  };
  const loader = new OverviewLoader(api as never);
  await loader.load('t', [forms[0]!]);
  const s = loader.snapshots.get('a');
  expect(s?.statsStatus).toBe('error');
  expect(s?.detailStatus).toBe('error');
});
