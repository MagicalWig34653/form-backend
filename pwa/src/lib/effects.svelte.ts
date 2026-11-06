/** Effect level per device: off | subtle (default) | full. "off" is forced by prefers-reduced-motion. */
export type EffectLevel = 'off' | 'subtle' | 'full';
export const effectLevels: readonly EffectLevel[] = ['off', 'subtle', 'full'];
const KEY = 'effects';
const state = $state<{ level: EffectLevel; reduced: boolean }>({ level: 'subtle', reduced: false });

function reducedQuery(): MediaQueryList | null {
  return typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : null;
}
function apply(): void {
  document.documentElement.dataset.effects = state.reduced ? 'off' : state.level;
}
try {
  const stored = localStorage.getItem(KEY);
  if (stored === 'off' || stored === 'subtle' || stored === 'full') state.level = stored;
} catch {
  /* Storage may be unavailable. */
}
const query = reducedQuery();
state.reduced = query?.matches ?? false;
query?.addEventListener?.('change', () => {
  state.reduced = reducedQuery()?.matches ?? false;
  apply();
});
apply();

export const effects = {
  /** The level the user chose. */
  get level() {
    return state.level;
  },
  /** The level in force: "off" whenever the system asks for reduced motion. */
  get effective(): EffectLevel {
    return state.reduced ? 'off' : state.level;
  },
  get forcedOff() {
    return state.reduced;
  },
  setLevel(level: EffectLevel): void {
    state.level = level;
    try {
      localStorage.setItem(KEY, level);
    } catch {
      /* Session-only preference. */
    }
    apply();
  },
};
