import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';
import { F, T, mock } from './helpers-screen-mock';

// UI polish behaviour: mobile order, full-width actions, chips, step footer; axe and 320 px.
const pages: [string, string][] = [
  ['Formular-Übersicht', `/t/${T}/f/${F}`],
  ['Einsendungen', `/t/${T}/f/${F}/entries`],
  ['Kunden', '/t'],
  ['Betrieb', '/ops'],
  ['Mail', `/t/${T}/f/${F}/mail`],
  ['Umstieg', '/migration'],
  ['Einstellungen', '/settings'],
  ['Einbindung', `/t/${T}/f/${F}/keys`],
  ['Konten', '/accounts'],
];

test.describe('UI-Feinschliff', () => {
  test.beforeEach(async ({ page }) => {
    await mock(page);
  });

  test('mobil: Zeitreihe steht vor den Aktionen, Einrichtung zuerst', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}`);
    const setup = page.getByRole('heading', { name: 'Einrichtung', exact: true });
    const chart = page.getByRole('figure', { name: /Zeitreihe/ });
    const actions = page.getByRole('heading', { name: 'Aktionen', exact: true });
    await expect(actions).toBeVisible();
    const y = async (l: typeof setup) => (await l.boundingBox())!.y;
    expect(await y(setup)).toBeLessThan(await y(chart));
    expect(await y(chart)).toBeLessThan(await y(actions));
  });

  test('Desktop: Aktionen bleiben in der Seitenspalte neben der Zeitreihe', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`/t/${T}/f/${F}`);
    const chart = await page.getByRole('figure', { name: /Zeitreihe/ }).boundingBox();
    const actions = await page
      .getByRole('heading', { name: 'Aktionen', exact: true })
      .boundingBox();
    expect(actions!.x).toBeGreaterThan(chart!.x + 300);
  });

  test('mobil: lokale Suche und Verwerfen nutzen die volle Breite', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}/entries`);
    const search = page.getByRole('button', { name: 'Lokal durchsuchen' });
    const discard = page.getByRole('button', { name: 'Suchdaten verwerfen' });
    await expect(search).toBeVisible();
    const a = (await search.boundingBox())!;
    const b = (await discard.boundingBox())!;
    expect(a.width).toBeGreaterThan(120);
    expect(b.width).toBeGreaterThan(120);
  });

  test('Kunden: Rechte erscheinen als Chips', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/t');
    const chips = page.getByRole('table').getByRole('list', { name: 'Ihre Rechte' }).first();
    await expect(chips.getByRole('listitem').first()).toBeVisible();
  });

  test('Umstieg mobil: Schrittzähler und Begründung stehen in einer Zeile Text', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto('/migration');
    const nav = page.getByTestId('step-nav');
    await expect(nav).toBeVisible();
    await expect(nav.locator('p').first()).toContainText('Schritt 1 von 5');
    await expect(nav.locator('p').first()).toContainText('Prüfen Sie zuerst');
  });

  test('Mail nennt fehlende Angaben und begründet das deaktivierte Zuweisen', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}/mail`);
    await expect(page.getByTestId('org-missing')).toContainText('Es fehlen:');
    await expect(page.getByTestId('org-missing')).toContainText('Betreff');
    const assign = page.getByRole('button', { name: 'Versandweg zuweisen' });
    await expect(assign).toBeDisabled();
    await expect(page.getByText('Wählen Sie zuerst eine Versandverbindung aus.')).toBeVisible();
  });

  test('Einstellungen mobil: technische Zeilen erst nach Schalter sichtbar', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto('/settings');
    const key = page.getByText('mcp.requestsPerMinute', { exact: true });
    await expect(page.getByTestId('meta-toggle')).toBeVisible();
    await expect(key).toBeHidden();
    await page.getByTestId('meta-toggle').click();
    await expect(key).toBeVisible();
  });

  test('Einstellungen Desktop: technische Zeilen zunächst sichtbar, per Schalter einklappbar', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/settings');
    const key = page.getByText('mcp.requestsPerMinute', { exact: true });
    await expect(key).toBeVisible();
    await page.getByTestId('meta-toggle').click();
    await expect(key).toBeHidden();
  });

  test('Einsendungen: lokaler Zeitraum erst nach Klick', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}/entries`);
    await expect(page.locator('#local-from')).toHaveCount(0);
    await page.getByRole('button', { name: 'Zeitraum einschränken' }).click();
    await expect(page.locator('#local-from')).toBeVisible();
  });

  test('Statistik: dünner Verlauf wird erklärt', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}`);
    await expect(page.getByTestId('sparse-note')).toContainText('nur an 2 von 14 Tagen');
  });

  test('Mail Desktop: Absenderadresse und -name stehen nebeneinander', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`/t/${T}/f/${F}/mail`);
    const a = (await page.locator('#mail-from').boundingBox())!;
    const b = (await page.locator('#mail-from-name').boundingBox())!;
    expect(Math.abs(a.y - b.y)).toBeLessThan(4);
    expect(b.x).toBeGreaterThan(a.x + a.width - 1);
  });

  test('Konten mobil: Zusatzangaben stehen gebündelt unter dem Namen', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto('/accounts');
    await expect(page.locator('[data-extras]').first()).toBeVisible();
  });

  test('Statistik: Conversion-Karte nennt die Formel statt leerer Fläche', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 800 });
    await page.goto(`/t/${T}/f/${F}`);
    await expect(page.getByText('Einsendungen ÷ Besuche')).toBeVisible();
  });

  test('Kunde A: Versandweg-Hinweis steht nur noch einmal (in der Einrichtung)', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`/t/${T}`);
    await expect(page.getByRole('heading', { name: 'Einrichtung', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: /Versandweg wählen/ })).toHaveCount(1);
  });

  test('Mail: Zuweisen-Button streckt sich nicht über die Spalte', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto(`/t/${T}/f/${F}/mail`);
    const b = (await page.getByRole('button', { name: 'Versandweg zuweisen' }).boundingBox())!;
    expect(b.width).toBeLessThan(300);
  });

  for (const [name, path] of pages)
    for (const scheme of ['light', 'dark'] as const)
      test(`${name} (${scheme}) bei 320 px: kein Seitenüberlauf, axe sauber`, async ({ page }) => {
        await page.emulateMedia({ colorScheme: scheme });
        await page.setViewportSize({ width: 320, height: 700 });
        await page.goto(path);
        await page.waitForLoadState('networkidle');
        // Name the offenders (outside intentionally scrollable regions) instead of a bare boolean.
        expect(
          await page.evaluate(() => {
            const scrolls = (el: Element) => {
              for (let n = el.parentElement; n && n !== document.body; n = n.parentElement) {
                const o = getComputedStyle(n).overflowX;
                if (o === 'auto' || o === 'scroll' || o === 'hidden') return true;
              }
              return false;
            };
            const offenders = [...document.querySelectorAll('body *')]
              .filter(
                (el) => el.getBoundingClientRect().right > window.innerWidth + 0.5 && !scrolls(el),
              )
              .slice(0, 6)
              .map(
                (el) =>
                  `${el.tagName.toLowerCase()}.${String(el.className).slice(0, 60)} → ${(el.textContent ?? '').trim().slice(0, 40)}`,
              );
            const page = document.documentElement.scrollWidth > window.innerWidth;
            return page
              ? [`scrollWidth ${document.documentElement.scrollWidth}`, ...offenders]
              : [];
          }),
        ).toEqual([]);
        const results = await new AxeBuilder({ page })
          .withTags(['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'])
          .analyze();
        expect(results.violations.map((v) => `${v.id}: ${v.nodes[0]?.target}`)).toEqual([]);
      });
});
