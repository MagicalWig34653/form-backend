export type Mode = 'light' | 'dark' | 'system';
export const accents = {
  blue: '#2563eb',
  violet: '#7c3aed',
  green: '#047857',
  orange: '#c2410c',
} as const;
export type Accent = keyof typeof accents;
const state = $state<{ dark: boolean; mode: Mode; accent: Accent }>({
  dark: document.documentElement.classList.contains('dark'),
  mode: 'system',
  accent: 'blue',
});
function store(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Session-only preference. */
  }
}
function apply(): void {
  state.dark =
    state.mode === 'system'
      ? matchMedia('(prefers-color-scheme: dark)').matches
      : state.mode === 'dark';
  document.documentElement.classList.toggle('dark', state.dark);
  const root = document.documentElement;
  root.dataset.accent = state.accent;
  root.style.setProperty('--ui-accent', accents[state.accent]);
  root.style.setProperty(
    '--ui-accent-ink',
    state.dark
      ? { blue: '#93c5fd', violet: '#c4b5fd', green: '#6ee7b7', orange: '#fdba74' }[state.accent]
      : { blue: '#1d4ed8', violet: accents.violet, green: accents.green, orange: '#9a3412' }[
          state.accent
        ],
  );
  root.style.setProperty(
    '--ui-accent-soft',
    `color-mix(in srgb, ${accents[state.accent]} 10%, var(--background))`,
  );
}
try {
  const mode = localStorage.getItem('theme');
  if (mode === 'light' || mode === 'dark') state.mode = mode;
  const accent = localStorage.getItem('accent');
  if (accent && Object.hasOwn(accents, accent)) state.accent = accent as Accent;
} catch {
  /* Storage may be unavailable. */
}
apply();
window.matchMedia?.('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (state.mode === 'system') apply();
});
export const theme = {
  get dark() {
    return state.dark;
  },
  get mode() {
    return state.mode;
  },
  get accent() {
    return state.accent;
  },
  setMode(mode: Mode): void {
    state.mode = mode;
    store('theme', mode);
    apply();
  },
  setAccent(accent: Accent): void {
    state.accent = accent;
    store('accent', accent);
    apply();
  },
  toggle(): void {
    this.setMode(state.dark ? 'light' : 'dark');
  },
};
