import { afterEach, beforeEach, expect, test, vi } from 'vitest';

let reduced = false;
let change: () => void = () => {};
async function load() {
  vi.resetModules();
  vi.stubGlobal('matchMedia', () => ({
    get matches() {
      return reduced;
    },
    addEventListener: (_e: string, cb: () => void) => {
      change = cb;
    },
  }));
  return (await import('./effects.svelte')).effects;
}
beforeEach(() => {
  reduced = false;
  localStorage.clear();
  delete document.documentElement.dataset.effects;
});
afterEach(() => vi.unstubAllGlobals());

test('defaults to subtle and marks the root element', async () => {
  const effects = await load();
  expect(effects.level).toBe('subtle');
  expect(document.documentElement.dataset.effects).toBe('subtle');
});
test('stored level is restored, invalid values are ignored', async () => {
  localStorage.setItem('effects', 'full');
  expect((await load()).level).toBe('full');
  localStorage.setItem('effects', 'wild');
  expect((await load()).level).toBe('subtle');
});
test('setLevel persists per device and updates the attribute', async () => {
  const effects = await load();
  effects.setLevel('off');
  expect(localStorage.getItem('effects')).toBe('off');
  expect(document.documentElement.dataset.effects).toBe('off');
});
test('prefers-reduced-motion forces off without overwriting the choice', async () => {
  reduced = true;
  localStorage.setItem('effects', 'full');
  const effects = await load();
  expect(effects.effective).toBe('off');
  expect(effects.level).toBe('full');
  expect(document.documentElement.dataset.effects).toBe('off');
  reduced = false;
  change();
  expect(document.documentElement.dataset.effects).toBe('full');
});
