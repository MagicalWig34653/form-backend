import { beforeAll, afterAll, expect, test, vi } from 'vitest';
let dark = false;
let change: () => void;
let theme: typeof import('./theme.svelte').theme;
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
test('invalid stored accent falls back to a known color', () => {
  expect(theme.accent).toBe('blue');
  expect(document.documentElement.style.getPropertyValue('--ui-accent')).toBe('#2563eb');
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
test('accent updates CSS and persists independently of the color scheme', () => {
  theme.setAccent('green');
  expect(localStorage.getItem('accent')).toBe('green');
  expect(document.documentElement.dataset.accent).toBe('green');
  expect(document.documentElement.style.getPropertyValue('--ui-accent-ink')).toBe('#6ee7b7');
  theme.setMode('light');
  expect(theme.accent).toBe('green');
  expect(document.documentElement.style.getPropertyValue('--ui-accent-ink')).toBe('#047857');
});
