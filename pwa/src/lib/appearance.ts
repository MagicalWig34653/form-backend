// Display preferences shared by the browser cache (localStorage) and the account (/me/preferences).
// Pure merge rules; the store lives in appearanceSync.svelte.ts.
import { ACCENTS, DEFAULT_ACCENT, LEGACY_ACCENTS } from './accents';

export type Mode = 'light' | 'dark' | 'system';
export type GlowStep = 0 | 1 | 2 | 3 | 4 | 5 | 6;
export interface Prefs {
  theme: Mode;
  accent: string;
  glow: GlowStep;
}

export const defaultPrefs: Readonly<Prefs> = { theme: 'system', accent: DEFAULT_ACCENT, glow: 0 };
const accentSet = new Set(ACCENTS.map((a) => a.id));

/** Only allowlisted keys and values survive; legacy accent ids are mapped. Anything else is dropped. */
export function parsePrefs(raw: unknown): Partial<Prefs> {
  const out: Partial<Prefs> = {};
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return out;
  const o = raw as Record<string, unknown>;
  if (o.theme === 'light' || o.theme === 'dark' || o.theme === 'system') out.theme = o.theme;
  if (typeof o.accent === 'string') {
    const accent = Object.hasOwn(LEGACY_ACCENTS, o.accent) ? LEGACY_ACCENTS[o.accent]! : o.accent;
    if (accentSet.has(accent)) out.accent = accent;
  }
  if (typeof o.glow === 'number' && Number.isInteger(o.glow) && o.glow >= 0 && o.glow <= 6)
    out.glow = o.glow as GlowStep;
  return out;
}

export function samePrefs(a: Prefs, b: Prefs): boolean {
  return a.theme === b.theme && a.accent === b.accent && a.glow === b.glow;
}

export interface LoginPlan {
  /** Values to show now and to keep in the browser cache (owner = the account). */
  apply: Prefs;
  /** Values to write to the account, or null. */
  upload: Prefs | null;
}

/**
 * Decides what happens after sign-in.
 * - The cache may be written by this account (`owner === account`), by nobody (`owner === null`: chosen on the
 *   login page or before preferences were stored in the account) or by another account.
 * - `dirty`: a change of this account in this browser has not reached the server yet; it wins once more.
 * - Otherwise the account wins. An empty account takes over the browser values only when they belong to this
 *   account or to nobody; values of another account are never carried over (defaults instead).
 */
export function planLogin(
  account: string,
  remote: Partial<Prefs>,
  local: Prefs,
  owner: string | null,
  dirty: boolean,
): LoginPlan {
  const ours = owner === account || owner === null;
  if (dirty && owner === account) return { apply: local, upload: local };
  const base = ours ? local : defaultPrefs;
  if (Object.keys(remote).length > 0) return { apply: { ...base, ...remote }, upload: null };
  if (!ours) return { apply: { ...defaultPrefs }, upload: null };
  return { apply: local, upload: samePrefs(local, defaultPrefs) ? null : local };
}
