import { expect, it, vi } from 'vitest';

vi.mock('$lib/api', () => ({ adminApi: { forms: vi.fn() } }));
vi.mock('$lib/session.svelte', () => ({ session: { me: { id: 'u1' }, expired: vi.fn() } }));
import { FormLists, LIST_PARALLEL, LIST_TTL_MS } from './formLists.svelte';

const ok = (n: string) => ({
  ok: true as const,
  data: {
    items: [{ id: n, name: n, active: true, currentReleaseId: null }],
    nextCursor: null,
  },
});
const fail = { ok: false as const, error: { kind: 'http', status: 500 } };

it('caches lists, refetches after the TTL and when forced', async () => {
  let now = 1000;
  const forms = vi.fn().mockResolvedValue(ok('f'));
  const lists = new FormLists(
    { forms } as never,
    () => now,
    () => false,
  );
  await lists.ensure(['a']);
  await lists.ensure(['a']);
  expect(forms).toHaveBeenCalledTimes(1);
  now += LIST_TTL_MS + 1;
  await lists.ensure(['a']);
  expect(forms).toHaveBeenCalledTimes(2);
  await lists.ensure(['a'], true);
  expect(forms).toHaveBeenCalledTimes(3);
  lists.invalidate('a');
  await lists.ensure(['a']);
  expect(forms).toHaveBeenCalledTimes(4);
});

it('fails per customer and retries a failed list on the next request', async () => {
  const forms = vi
    .fn()
    .mockImplementation((tenant: string) => Promise.resolve(tenant === 'b' ? fail : ok(tenant)));
  const lists = new FormLists({ forms } as never, Date.now, () => false);
  await lists.ensure(['a', 'b']);
  expect(lists.states.get('a')?.status).toBe('ready');
  expect(lists.states.get('b')).toMatchObject({ status: 'error', items: [] });
  await lists.ensure(['a', 'b']);
  expect(forms.mock.calls.filter((c) => c[0] === 'b')).toHaveLength(2);
  expect(forms.mock.calls.filter((c) => c[0] === 'a')).toHaveLength(1);
});

it('shares an in-flight request and bounds parallelism', async () => {
  let running = 0;
  let peak = 0;
  const forms = vi.fn().mockImplementation(async (tenant: string) => {
    running++;
    peak = Math.max(peak, running);
    await new Promise((r) => setTimeout(r, 5));
    running--;
    return ok(tenant);
  });
  const lists = new FormLists({ forms } as never, Date.now, () => false);
  const ids = Array.from({ length: 12 }, (_, i) => `t${i}`);
  await Promise.all([lists.ensure(ids), lists.ensure(ids)]);
  expect(forms).toHaveBeenCalledTimes(12);
  expect(peak).toBeLessThanOrEqual(LIST_PARALLEL * 2);
  expect(peak).toBeGreaterThan(1);
});

it('drops the cache when another account signs in', async () => {
  const forms = vi.fn().mockResolvedValue(ok('f'));
  const lists = new FormLists({ forms } as never, Date.now, () => false);
  lists.bind('u1');
  await lists.ensure(['a']);
  lists.bind('u2');
  expect(lists.states.size).toBe(0);
});
