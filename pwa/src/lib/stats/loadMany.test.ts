import { expect, it, vi } from 'vitest';
import { MAX_PARALLEL, OverviewLoader } from './loader.svelte';

const item = (id: string) => ({ id, name: id, active: true, currentReleaseId: null });

it('loads several customers with the right customer per request, bounded and failing per form', async () => {
  let running = 0;
  let peak = 0;
  const seen: string[] = [];
  const slow = async <T>(value: T): Promise<T> => {
    running++;
    peak = Math.max(peak, running);
    await new Promise((r) => setTimeout(r, 2));
    running--;
    return value;
  };
  const api = {
    statistics: vi.fn(async (tenant: string, form: string) => {
      seen.push(`${tenant}/${form}`);
      return slow(
        form === 'bad'
          ? { ok: false as const, error: { kind: 'http' as const, status: 500 } }
          : {
              ok: true as const,
              data: {
                from: '',
                to: '2026-11-01',
                total: 1,
                visits: 4,
                begins: 0,
                submits: 1,
                abandons: 0,
                conversion: 0.25,
                days: [],
              },
            },
      );
    }),
    form: vi.fn(() => slow({ ok: true as const, data: {} })),
    entries: vi.fn(() => slow({ ok: true as const, data: { items: [], nextCursor: null } })),
  };
  const loader = new OverviewLoader(api as never);
  const forms = (ids: string[]) => ids.map(item);
  await loader.loadMany([
    { tenant: 'a', forms: forms(['f1', 'f2', 'f3', 'f4', 'f5']) },
    { tenant: 'b', forms: forms(['g1', 'bad', 'g3', 'g4', 'g5']) },
  ]);
  expect(seen).toContain('a/f1');
  expect(seen).toContain('b/g1');
  expect(peak).toBeLessThanOrEqual(MAX_PARALLEL);
  expect(loader.snapshots.get('f1')?.statsStatus).toBe('ready');
  expect(loader.snapshots.get('bad')?.statsStatus).toBe('error');
  expect(loader.snapshots.get('bad')?.entriesStatus).toBe('ready');
  // A later load of one customer drops forms that are no longer listed.
  await loader.load('a', forms(['f1']));
  expect([...loader.snapshots.keys()]).toEqual(['f1']);
});
