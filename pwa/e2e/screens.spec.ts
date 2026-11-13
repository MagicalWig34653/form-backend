import { expect, test } from '@playwright/test';
import { F, T, mock } from './helpers-screen-mock';

// Visual review helper: SHOTS=dir npx playwright test e2e/screens.spec.ts (skipped otherwise).
const out = process.env.SHOTS;
const routes: [string, string][] = [
  ['gesamt', '/overview'],
  ['formularverzeichnis', '/forms'],
  ['kunden', '/t'],
  ['formulare', `/t/${T}`],
  ['formular', `/t/${T}/f/${F}`],
  ['felder', `/t/${T}/f/${F}/fields`],
  ['ablauf', `/t/${T}/f/${F}/flow`],
  ['einsendungen', `/t/${T}/f/${F}/entries`],
  ['mail', `/t/${T}/f/${F}/mail`],
  ['webhooks', `/t/${T}/f/${F}/webhooks`],
  ['aufbewahrung', `/t/${T}/f/${F}/storage`],
  ['veroeffentlichen', `/t/${T}/f/${F}/publish`],
  ['einbindung', `/t/${T}/f/${F}/keys`],
  ['mitglieder', `/t/${T}/members`],
  ['konto', '/account'],
  ['tokens', '/api-tokens'],
  ['einstellungen', '/settings'],
  ['verbindungen', '/connections'],
  ['konten', '/accounts'],
  ['einrichtung', '/installation'],
  ['umstieg', '/migration'],
  ['betrieb', '/ops'],
  ['protokoll', '/audit'],
];
test.describe('screenshots', () => {
  test.skip(!out, 'set SHOTS');
  for (const scheme of ['light', 'dark'] as const)
    for (const [size, viewport] of [
      ['desktop', { width: 1280, height: 800 }],
      ['mobil', { width: 390, height: 800 }],
    ] as const)
      test(`${scheme} ${size}`, async ({ page }) => {
        test.setTimeout(240_000);
        await page.setViewportSize(viewport);
        await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
        const errors: string[] = [];
        page.on('pageerror', (e) => errors.push(e.message));
        await mock(page);
        for (const [name, path] of routes) {
          await page.goto(path);
          await page.waitForLoadState('networkidle');
          await page.screenshot({
            path: `${out}/${name}-${scheme === 'light' ? 'hell' : 'dunkel'}-${size}.png`,
            fullPage: true,
          });
        }
        expect(errors).toEqual([]);
      });
});

// Menus and dialogs (opt-in like the pages above).
test.describe('screenshots menus', () => {
  test.skip(!out, 'set SHOTS');
  for (const scheme of ['light', 'dark'] as const)
    for (const [size, viewport] of [
      ['desktop', { width: 1280, height: 800 }],
      ['mobil', { width: 390, height: 800 }],
    ] as const)
      test(`menus ${scheme} ${size}`, async ({ page }) => {
        test.setTimeout(120_000);
        await page.setViewportSize(viewport);
        await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
        await mock(page);
        const suffix = `${scheme === 'light' ? 'hell' : 'dunkel'}-${size}`;
        const shot = (name: string) =>
          page.screenshot({ path: `${out}/menue-${name}-${suffix}.png` });
        await page.goto(`/t/${T}/f/${F}/entries`);
        await page.waitForLoadState('networkidle');
        if (size === 'mobil') {
          await page.getByRole('button', { name: 'Navigation öffnen' }).click();
          await shot('navigation');
          await page.keyboard.press('Escape');
        } else {
          await page.keyboard.press('g');
          await page.keyboard.press('b');
          await page.getByRole('listbox', { name: 'Bereiche' }).waitFor();
          await shot('bereich');
          await page.keyboard.press('Escape');
        }
        await page
          .getByRole('button', { name: /Suchen/ })
          .first()
          .click();
        await shot('palette');
        await page.keyboard.press('Escape');
        await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
        await shot('darstellung');
        await page.keyboard.press('Escape');
      });
});
