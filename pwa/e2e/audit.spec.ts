import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';
import { mock } from './helpers-screen-mock';

test.describe('Protokoll', () => {
  test.beforeEach(async ({ page }) => {
    await mock(page);
  });

  test('erscheint im Menü unter System und zeigt Einträge', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/ops');
    await page.getByRole('link', { name: 'Protokoll' }).first().click();
    await expect(page).toHaveURL(/\/audit$/);
    await expect(page.getByRole('heading', { name: 'Protokoll', exact: true })).toBeVisible();
    await expect(page.getByText('key.rotate').first()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Anwenden' })).toBeEnabled();
    await page.waitForLoadState('networkidle');
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  });

  test('Leerzustand und Fehlerzustand sind unterscheidbar', async ({ page }) => {
    await page.goto('/audit');
    await page.getByLabel('Aktion', { exact: true }).fill('none');
    await page.getByRole('button', { name: 'Anwenden' }).click();
    await expect(page.getByText('Keine passenden Einträge.')).toBeVisible();
    await page.getByLabel('Aktion', { exact: true }).fill('forbidden');
    await page.getByRole('button', { name: 'Anwenden' }).click();
    await expect(page.getByRole('alert')).toContainText('Berechtigung');
    await expect(page.getByText('Keine passenden Einträge.')).toHaveCount(0);
  });

  test('320 px: Kartenliste statt Tabelle, kein Seitenüberlauf, axe sauber', async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 700 });
    await page.goto('/audit');
    await expect(page.getByText('key.rotate').first()).toBeVisible();
    await expect(page.getByRole('button', { name: 'Anwenden' })).toBeEnabled();
    await page.waitForLoadState('networkidle');
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  });
});
