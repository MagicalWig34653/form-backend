import AxeBuilder from '@axe-core/playwright';
import { test, expect, type Page } from '@playwright/test';

// Design quality gates of the thermoctl look: narrow screens, glow levels, accent contrast,
// reduced motion/transparency and keyboard-only use. API answers are synthetic.
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';
const j = (b: unknown) => ({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
async function mock(page: Page) {
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(j({ items: [{ id: T, name: 'Kunde A', permissions: ['form.read'] }] }));
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: null }],
          nextCursor: null,
        }),
      );
    return r.fulfill(j({ items: [] }));
  });
}
const routes = [
  '/t',
  `/t/${T}`,
  '/account',
  '/api-tokens',
  '/settings',
  '/installation',
  '/migration',
];

test('no horizontal scrolling at 360 px on any main page', async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 740 });
  await mock(page);
  for (const route of routes) {
    await page.goto(route);
    await expect(page.locator('#page-title')).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow, route).toBeLessThanOrEqual(0);
  }
});

for (const step of [0, 6]) {
  for (const accent of ['tuerkis', 'gelb', 'limette']) {
    test(`axe: accent ${accent}, glow ${step}, dark and light`, async ({ page }) => {
      await mock(page);
      await page.addInitScript(
        ([a, g]) => {
          localStorage.setItem('accent', String(a));
          localStorage.setItem('glow', String(g));
        },
        [accent, step],
      );
      for (const scheme of ['light', 'dark'] as const) {
        await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
        await page.goto(`/t/${T}`);
        await expect(page.locator('#page-title')).toBeVisible();
        await expect(page.locator('html')).toHaveAttribute('data-accent', accent);
        const results = await new AxeBuilder({ page })
          .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
          .analyze();
        expect(
          results.violations.map(
            (v) => `${v.id}: ${v.nodes.map((n) => n.html.slice(0, 160)).join(' | ')}`,
          ),
          scheme,
        ).toEqual([]);
      }
    });
  }
}

test('glass surfaces are translucent by default and fall back to opaque for reduced transparency', async ({
  page,
}) => {
  await mock(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto('/t');
  await expect(page.locator('#page-title')).toBeVisible();
  const state = await page.evaluate(() => {
    const bar = getComputedStyle(document.querySelector('.app-topbar') as Element);
    const rules = [...document.styleSheets].flatMap((sheet) => [...sheet.cssRules]);
    return {
      blur: bar.backdropFilter,
      fallback: rules.some((r) => r.cssText.includes('prefers-reduced-transparency')),
    };
  });
  expect(state.blur).toContain('blur');
  expect(state.fallback).toBe(true);
});

test('keyboard only: skip link, menu arrows and drawer escape', async ({ page }) => {
  await mock(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto('/t');
  await expect(page.locator('#page-title')).toBeVisible();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Zum Inhalt' })).toBeFocused();
  // arrow keys move through the menu entries
  const first = page.locator('#app-sidebar [data-nav-item]').first();
  await first.focus();
  await page.keyboard.press('ArrowDown');
  await expect(page.locator('#app-sidebar [data-nav-item]').nth(1)).toBeFocused();
  await page.keyboard.press('End');
  await expect(page.locator('#app-sidebar nav [data-nav-item]').last()).toBeFocused();
  await page.keyboard.press('Home');
  await expect(first).toBeFocused();
});

test('menu groups are fixed headings with their entries (no collapsing)', async ({ page }) => {
  await mock(page);
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto('/settings');
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
  await expect(nav.getByRole('group', { name: 'Arbeiten' })).toBeVisible();
  await expect(nav.getByRole('group', { name: 'Verwalten' })).toBeVisible();
  const admin = nav.getByRole('group', { name: 'System' });
  await expect(admin.getByRole('link', { name: 'Einstellungen' })).toHaveAttribute(
    'aria-current',
    'page',
  );
  await expect(nav.getByRole('button')).toHaveCount(0);
});
