// Keeps the display preferences in the account. The browser cache (theme.svelte.ts, localStorage) paints first;
// after sign-in the account wins (rules in appearance.ts). Changes are applied at once and written debounced.
import type { ApiResult } from './api/client';
import type { AccountPreferences } from './api/admin';
import { parsePrefs, planLogin, type Prefs } from './appearance';

/** localStorage: the account whose values the cache holds; missing = chosen without an account. */
export const OWNER_KEY = 'appearance-account';
/** localStorage: account id whose last change has not reached the server yet. */
export const DIRTY_KEY = 'appearance-dirty';

export interface AppearanceDeps {
  api: {
    preferences(): Promise<ApiResult<AccountPreferences>>;
    savePreferences(values: AccountPreferences): Promise<ApiResult<AccountPreferences>>;
  };
  theme: {
    snapshot(): Prefs;
    replace(prefs: Prefs): void;
    onChange(callback: ((prefs: Prefs) => void) | null): void;
  };
  debounceMs?: number;
  retryMs?: number;
  maxRetries?: number;
}

function read(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}
function write(key: string, value: string | null): void {
  try {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  } catch {
    /* Cache only. */
  }
}

export function createAppearanceSync(deps: AppearanceDeps) {
  const debounceMs = deps.debounceMs ?? 600;
  const retryMs = deps.retryMs ?? 30_000;
  const maxRetries = deps.maxRetries ?? 5;
  const state = $state<{ account: string | null; saveFailed: boolean }>({
    account: null,
    saveFailed: false,
  });
  let generation = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let retries = 0;

  function cancel(): void {
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
  }
  function schedule(ms: number): void {
    cancel();
    timer = setTimeout(() => void flush(), ms);
  }
  async function save(values: Prefs): Promise<void> {
    const run = generation;
    const account = state.account;
    if (!account) return;
    const r = await deps.api.savePreferences({ ...values });
    if (run !== generation) return;
    if (r.ok) {
      retries = 0;
      state.saveFailed = false;
      if (read(DIRTY_KEY) === account) write(DIRTY_KEY, null);
      return;
    }
    state.saveFailed = true;
    if (retries < maxRetries) {
      retries++;
      schedule(retryMs);
    }
  }
  async function flush(): Promise<void> {
    timer = undefined;
    await save(deps.theme.snapshot());
  }
  function changed(): void {
    const account = state.account;
    // Without an account the choice belongs to nobody (login and setup pages).
    write(OWNER_KEY, account);
    if (!account) return;
    write(DIRTY_KEY, account);
    retries = 0;
    schedule(debounceMs);
  }
  deps.theme.onChange(changed);

  return {
    get account() {
      return state.account;
    },
    get saveFailed() {
      return state.saveFailed;
    },
    /** Signed-in account (null = signed out). Loads once per sign-in and page load. */
    async bind(account: string | null): Promise<void> {
      if (account === state.account) return;
      generation++;
      cancel();
      retries = 0;
      state.account = account;
      state.saveFailed = false;
      if (!account) return;
      const run = generation;
      const r = await deps.api.preferences();
      if (run !== generation) return;
      // Account unreachable: keep what the browser shows, never upload blindly.
      if (!r.ok) return;
      const plan = planLogin(
        account,
        parsePrefs(r.data),
        deps.theme.snapshot(),
        read(OWNER_KEY),
        read(DIRTY_KEY) === account,
      );
      deps.theme.replace(plan.apply);
      write(OWNER_KEY, account);
      if (read(DIRTY_KEY) !== account) write(DIRTY_KEY, null);
      if (plan.upload) await save(plan.upload);
    },
  };
}
