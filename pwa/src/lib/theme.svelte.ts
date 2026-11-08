// Darstellung: Hell/Dunkel/System, Akzentfarbe (20 Vorgaben) und Glow-Stufe. Die Wahl liegt im Browser
// (localStorage); jeder Zugriff darauf ist abgesichert, ohne Speicher gilt die Vorgabe.
import { accentTokens } from './accent';
import { ACCENTS, DEFAULT_ACCENT, LEGACY_ACCENTS } from './accents';

export type Mode = 'light' | 'dark' | 'system';
export type Accent = string;
export type GlowStep = 0 | 1 | 2 | 3 | 4 | 5 | 6;
export const accentIds: readonly string[] = ACCENTS.map((a) => a.id);
export const accents: Readonly<Record<string, string>> = Object.fromEntries(
  ACCENTS.map((a) => [a.id, a.hex]),
);
export const glowSteps: readonly GlowStep[] = [0, 1, 2, 3, 4, 5, 6];

const state = $state<{ dark: boolean; mode: Mode; accent: Accent; glow: GlowStep }>({
  dark: document.documentElement.classList.contains('dark'),
  mode: 'system',
  accent: DEFAULT_ACCENT,
  glow: 0,
});
function store(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* Nur für diese Sitzung. */
  }
}
function apply(): void {
  state.dark =
    state.mode === 'system'
      ? matchMedia('(prefers-color-scheme: dark)').matches
      : state.mode === 'dark';
  const root = document.documentElement;
  root.classList.toggle('dark', state.dark);
  root.dataset.accent = state.accent;
  if (state.glow > 0) {
    root.dataset.glow = 'on';
    root.dataset.glowStep = String(state.glow);
  } else {
    delete root.dataset.glow;
    delete root.dataset.glowStep;
  }
  const tokens = accentTokens(accents[state.accent] ?? '', state.dark);
  if (!tokens) return;
  const vars: Record<string, string> = {
    '--primary': tokens.primary,
    '--primary-foreground': tokens.foreground,
    // Fokusring und Akzenttext nutzen die Tinte mit gesichertem Kontrast, nicht die Rohfarbe.
    '--ring': tokens.ink,
    '--ui-accent': tokens.primary,
    '--ui-accent-ink': tokens.ink,
    '--ui-accent-soft': tokens.soft,
  };
  for (const [key, value] of Object.entries(vars)) root.style.setProperty(key, value);
}
try {
  const mode = localStorage.getItem('theme');
  if (mode === 'light' || mode === 'dark') state.mode = mode;
  const stored = localStorage.getItem('accent') ?? '';
  const accent = LEGACY_ACCENTS[stored] ?? stored;
  if (Object.hasOwn(accents, accent)) state.accent = accent;
  const glow = Number(localStorage.getItem('glow'));
  if (Number.isInteger(glow) && glow >= 0 && glow <= 6) state.glow = glow as GlowStep;
} catch {
  /* Speicher nicht verfügbar. */
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
  get glow() {
    return state.glow;
  },
  setMode(mode: Mode): void {
    state.mode = mode;
    store('theme', mode);
    apply();
  },
  setAccent(accent: Accent): void {
    if (!Object.hasOwn(accents, accent)) return;
    state.accent = accent;
    store('accent', accent);
    apply();
  },
  setGlow(step: GlowStep): void {
    state.glow = step;
    store('glow', String(step));
    apply();
  },
  toggle(): void {
    this.setMode(state.dark ? 'light' : 'dark');
  },
};
