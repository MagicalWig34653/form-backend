import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { ApiResult } from './api/client';
import type { AccountPreferences } from './api/admin';
import { defaultPrefs, parsePrefs, planLogin, type Prefs } from './appearance';
import { createAppearanceSync, DIRTY_KEY, OWNER_KEY } from './appearanceSync.svelte';

const ok = <T>(data: T): ApiResult<T> => ({ ok: true, data });
const fail: ApiResult<never> = { ok: false, error: { kind: 'network', message: 'x' } };
const mine: Prefs = { theme: 'dark', accent: 'blau', glow: 3 };

function setup(remote: ApiResult<AccountPreferences>, saves: ApiResult<AccountPreferences>[] = []) {
  let current: Prefs = { ...defaultPrefs };
  let listener: ((p: Prefs) => void) | null = null;
  const theme = {
    snapshot: () => ({ ...current }),
    replace: vi.fn((p: Prefs) => {
      current = { ...p };
    }),
    onChange: (cb: ((p: Prefs) => void) | null) => {
      listener = cb;
    },
    /** A change in the menu. */
    user(p: Partial<Prefs>) {
      current = { ...current, ...p };
      listener?.({ ...current });
    },
    set(p: Prefs) {
      current = { ...p };
    },
  };
  const savePreferences = vi.fn(async (v: AccountPreferences) => saves.shift() ?? ok(v));
  const api = { preferences: vi.fn(async () => remote), savePreferences };
  const sync = createAppearanceSync({ api, theme, debounceMs: 100, retryMs: 1000, maxRetries: 1 });
  return { sync, theme, api };
}

beforeEach(() => {
  localStorage.clear();
  vi.useFakeTimers();
});
afterEach(() => {
  vi.useRealTimers();
});

test('parsePrefs keeps only allowlisted values and maps legacy accents', () => {
  expect(parsePrefs({ theme: 'dark', accent: 'blue', glow: 2, other: 1 })).toEqual({
    theme: 'dark',
    accent: 'blau',
    glow: 2,
  });
  expect(parsePrefs({ theme: 'neon', accent: '__proto__', glow: 2.5 })).toEqual({});
  expect(parsePrefs({ items: [] })).toEqual({});
  expect(parsePrefs(null)).toEqual({});
});

test('planLogin: account wins, empty account takes own or unclaimed values, never those of another account', () => {
  expect(planLogin('a', { theme: 'light' }, mine, 'a', false)).toEqual({
    apply: { ...mine, theme: 'light' },
    upload: null,
  });
  expect(planLogin('a', {}, mine, 'a', false)).toEqual({ apply: mine, upload: mine });
  expect(planLogin('a', {}, mine, null, false)).toEqual({ apply: mine, upload: mine });
  expect(planLogin('a', {}, mine, 'b', false)).toEqual({ apply: defaultPrefs, upload: null });
  expect(planLogin('a', { glow: 1 }, mine, 'b', false).apply).toEqual({ ...defaultPrefs, glow: 1 });
  expect(planLogin('a', {}, { ...defaultPrefs }, null, false).upload).toBeNull();
  // An unsent change of this account wins once more.
  expect(planLogin('a', { theme: 'light' }, mine, 'a', true)).toEqual({
    apply: mine,
    upload: mine,
  });
  expect(planLogin('a', { theme: 'light' }, mine, 'b', true).upload).toBeNull();
});

test('account values are applied over the browser cache', async () => {
  const { sync, theme, api } = setup(ok({ theme: 'dark', accent: 'rot', glow: 2 }));
  theme.set(mine);
  localStorage.setItem(OWNER_KEY, 'a');
  await sync.bind('a');
  expect(theme.replace).toHaveBeenCalledWith({ theme: 'dark', accent: 'rot', glow: 2 });
  expect(api.savePreferences).not.toHaveBeenCalled();
  expect(localStorage.getItem(OWNER_KEY)).toBe('a');
  // Same account again: no second load.
  await sync.bind('a');
  expect(api.preferences).toHaveBeenCalledTimes(1);
});

test('an empty account takes over the values chosen in this browser once', async () => {
  const { sync, theme, api } = setup(ok({}));
  theme.set(mine);
  await sync.bind('a');
  expect(api.savePreferences).toHaveBeenCalledWith(mine);
  expect(localStorage.getItem(OWNER_KEY)).toBe('a');
});

test('switching accounts does not carry the previous account over', async () => {
  const { sync, theme, api } = setup(ok({}));
  theme.set(mine);
  localStorage.setItem(OWNER_KEY, 'a');
  await sync.bind(null);
  await sync.bind('b');
  expect(api.savePreferences).not.toHaveBeenCalled();
  expect(theme.snapshot()).toEqual(defaultPrefs);
  expect(localStorage.getItem(OWNER_KEY)).toBe('b');
});

test('a change is applied at once and written debounced with the full state', async () => {
  const { sync, theme, api } = setup(ok({ theme: 'light' }));
  await sync.bind('a');
  theme.user({ accent: 'gruen' });
  theme.user({ glow: 4 });
  expect(api.savePreferences).not.toHaveBeenCalled();
  expect(localStorage.getItem(DIRTY_KEY)).toBe('a');
  await vi.advanceTimersByTimeAsync(100);
  expect(api.savePreferences).toHaveBeenCalledTimes(1);
  expect(api.savePreferences).toHaveBeenCalledWith({ theme: 'light', accent: 'gruen', glow: 4 });
  expect(localStorage.getItem(DIRTY_KEY)).toBeNull();
  expect(sync.saveFailed).toBe(false);
});

test('a failed save keeps the choice, shows the hint and retries later', async () => {
  const { sync, theme, api } = setup(ok({}), [fail]);
  await sync.bind('a');
  theme.user({ theme: 'dark' });
  await vi.advanceTimersByTimeAsync(100);
  expect(sync.saveFailed).toBe(true);
  expect(theme.snapshot().theme).toBe('dark');
  expect(localStorage.getItem(DIRTY_KEY)).toBe('a');
  await vi.advanceTimersByTimeAsync(1000);
  expect(api.savePreferences).toHaveBeenCalledTimes(2);
  expect(sync.saveFailed).toBe(false);
  expect(localStorage.getItem(DIRTY_KEY)).toBeNull();
});

test('an unsent change wins over the account after a reload', async () => {
  localStorage.setItem(OWNER_KEY, 'a');
  localStorage.setItem(DIRTY_KEY, 'a');
  const { sync, theme, api } = setup(ok({ theme: 'light' }));
  theme.set(mine);
  await sync.bind('a');
  expect(theme.snapshot()).toEqual(mine);
  expect(api.savePreferences).toHaveBeenCalledWith(mine);
});

test('signing out cancels a pending save; changes without an account belong to nobody', async () => {
  const { sync, theme, api } = setup(ok({}));
  await sync.bind('a');
  theme.user({ glow: 5 });
  await sync.bind(null);
  await vi.advanceTimersByTimeAsync(1000);
  expect(api.savePreferences).not.toHaveBeenCalled();
  theme.user({ glow: 2 });
  expect(localStorage.getItem(OWNER_KEY)).toBeNull();
});

test('an unreachable account keeps the browser values and uploads nothing', async () => {
  const { sync, theme, api } = setup(fail);
  theme.set(mine);
  await sync.bind('a');
  expect(theme.replace).not.toHaveBeenCalled();
  expect(api.savePreferences).not.toHaveBeenCalled();
});
