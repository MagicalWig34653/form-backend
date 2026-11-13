import { beforeAll, afterAll, expect, test, vi } from 'vitest';
let dark = false;
let change: () => void;
let theme: typeof import('./theme.svelte').theme;
const root = document.documentElement;
beforeAll(async () => {
  vi.stubGlobal('matchMedia', () => ({
    matches: dark,
    addEventListener: (_event: string, callback: () => void) => {
      change = callback;
    },
  }));
  localStorage.setItem('accent', '__proto__');
  localStorage.setItem('theme', 'system');
  theme = (await import('./theme.svelte')).theme;
});
afterAll(() => {
  vi.unstubAllGlobals();
  localStorage.clear();
});
test('invalid stored accent falls back to the default turquoise', () => {
  expect(theme.accent).toBe('tuerkis');
  expect(root.style.getPropertyValue('--ui-accent')).toBe('#0f766e');
  expect(theme.glow).toBe(0);
  expect(root.dataset.glow).toBeUndefined();
});
test('system changes apply only while the system mode is selected', () => {
  dark = true;
  change();
  expect(theme.dark).toBe(true);
  theme.setMode('light');
  change();
  expect(theme.dark).toBe(false);
  expect(localStorage.getItem('theme')).toBe('light');
  theme.setMode('system');
  expect(theme.dark).toBe(true);
});
test('accent updates the tokens, persists and keeps the text ink readable in both schemes', () => {
  theme.setAccent('gelb');
  expect(localStorage.getItem('accent')).toBe('gelb');
  expect(root.dataset.accent).toBe('gelb');
  expect(root.style.getPropertyValue('--ui-accent')).toBe('#eab308');
  // light yellow needs black text on the button and a darkened ink for text on white
  theme.setMode('light');
  expect(root.style.getPropertyValue('--primary-foreground')).toBe('#000000');
  const ink = root.style.getPropertyValue('--ui-accent-ink');
  expect(ink).toMatch(/^rgb\(/);
  expect(ink).not.toBe('rgb(234 179 8)');
  expect(root.style.getPropertyValue('--ring')).toBe(ink);
  theme.setMode('dark');
  expect(root.style.getPropertyValue('--ui-accent-ink')).toBe('rgb(234 179 8)');
  expect(theme.accent).toBe('gelb');
});
test('unknown accents are ignored', () => {
  theme.setAccent('nicht-vorhanden');
  expect(theme.accent).toBe('gelb');
});
test('glow step switches the data attributes and persists', () => {
  theme.setGlow(3);
  expect(root.dataset.glow).toBe('on');
  expect(root.dataset.glowStep).toBe('3');
  expect(localStorage.getItem('glow')).toBe('3');
  theme.setGlow(0);
  expect(root.dataset.glow).toBeUndefined();
});
test('account values replace the choice without counting as a user change', () => {
  const seen: unknown[] = [];
  theme.onChange((p) => seen.push(p));
  theme.replace({ theme: 'light', accent: 'rot', glow: 2 });
  expect(seen).toEqual([]);
  expect(theme.snapshot()).toEqual({ theme: 'light', accent: 'rot', glow: 2 });
  expect(localStorage.getItem('accent')).toBe('rot');
  expect(root.dataset.glowStep).toBe('2');
  theme.setAccent('blau');
  expect(seen).toEqual([{ theme: 'light', accent: 'blau', glow: 2 }]);
  theme.onChange(null);
});
