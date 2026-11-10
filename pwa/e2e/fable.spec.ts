import AxeBuilder from '@axe-core/playwright';
import { test, expect, type Page } from '@playwright/test';

const A = 'aaaaaaaa-1111-4111-8111-11111111111a';
const B = 'bbbbbbbb-1111-4111-8111-11111111111b';
const FA = '22222222-2222-4222-8222-222222222222';
const FB = '33333333-3333-4333-8333-333333333333';

async function mock(page: Page, opts: { admin?: boolean } = {}) {
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  const rights = ['form.read', 'draft.write', 'release.publish', 'key.manage', 'identity.manage'];
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me')
      return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: opts.admin ?? true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            { id: A, name: 'Kunde A', permissions: rights },
            { id: B, name: 'Kunde B', permissions: ['form.read'] },
          ],
        }),
      );
    if (p === `/tenants/${A}/forms`)
      return r.fulfill(
        j({
          items: [
            { id: FA, name: 'Kontakt', active: true, currentReleaseId: 'r1' },
            {
              id: '44444444-4444-4444-8444-444444444444',
              name: 'Entwurf',
              active: false,
              currentReleaseId: null,
            },
          ],
          nextCursor: null,
        }),
      );
    if (p === `/tenants/${B}/forms`)
      return r.fulfill(
        j({
          items: [{ id: FB, name: 'Angebot', active: false, currentReleaseId: 'r2' }],
          nextCursor: null,
        }),
      );
    if (p.endsWith('/members')) return r.fulfill(j({ items: [], assignable: [] }));
    return r.fulfill(j({ items: [] }));
  });
}

test('Formularverzeichnis: alle Kunden, Status in Worten, Kundenfilter entfernbar', async ({
  page,
}) => {
  await mock(page);
  await page.goto('/forms');
  const table = page.getByRole('table', { name: 'Formulare' });
  await expect(table.getByRole('link', { name: 'Kontakt' })).toBeVisible();
  await expect(table.getByRole('link', { name: 'Angebot' })).toBeVisible();
  await expect(page.getByText('3 Formulare')).toBeVisible();
  await expect(table.getByText('Live')).toBeVisible();
  await expect(table.getByText('Entwurf', { exact: true }).first()).toBeVisible();
  await expect(table.getByText('Pausiert')).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);

  await page.goto(`/forms?kunde=${B}`);
  await expect(table.getByRole('link', { name: 'Angebot' })).toBeVisible();
  await expect(table.getByRole('link', { name: 'Kontakt' })).toHaveCount(0);
  await page.getByRole('button', { name: /Filter „Kunde: Kunde B“ entfernen/ }).click();
  await expect(page).toHaveURL('/forms');
  await expect(table.getByRole('link', { name: 'Kontakt' })).toBeVisible();
  await table.getByRole('link', { name: 'Angebot' }).click();
  await expect(page).toHaveURL(`/t/${B}/f/${FB}`);
});

test('Menüs: Systemseiten nur für die Systemadministration', async ({ page }) => {
  await mock(page, { admin: false });
  await page.goto('/overview');
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
  await expect(nav.getByRole('group', { name: 'Bereich' })).toBeVisible();
  await expect(nav.getByRole('group', { name: 'Verwalten' })).toBeVisible();
  await expect(nav.getByRole('group', { name: 'System' })).toHaveCount(0);
  await expect(nav.getByRole('link', { name: 'Einstellungen' })).toHaveCount(0);
});

test('Kunde: Reiter Formulare und Mitglieder, Mitglieder nur mit Recht', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${A}`);
  await expect(page.getByRole('heading', { level: 1, name: 'Kunde A' })).toBeVisible();
  const tabs = page.getByRole('navigation', { name: 'Bereiche des Kunden' });
  await expect(tabs.getByRole('link', { name: 'Formulare' })).toHaveAttribute(
    'aria-current',
    'page',
  );
  await tabs.getByRole('link', { name: 'Mitglieder' }).click();
  await expect(page).toHaveURL(`/t/${A}/members`);
  await expect(tabs.getByRole('link', { name: 'Mitglieder' })).toHaveAttribute(
    'aria-current',
    'page',
  );
  await page.goto(`/t/${B}`);
  await expect(page.getByRole('heading', { level: 1, name: 'Kunde B' })).toBeVisible();
  await expect(tabs.getByRole('link', { name: 'Mitglieder' })).toHaveCount(0);
});

test('Formular: neun Reiter in Arbeitsreihenfolge, jeder mit eigener Adresse', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${A}/f/${FA}`);
  const tabs = page.getByRole('navigation', { name: 'Bereiche des Formulars' });
  await expect(tabs.getByRole('link')).toHaveText([
    'Übersicht',
    'Felder',
    'Ablauf',
    'Einsendungen',
    'Mail',
    'Webhooks',
    'Aufbewahrung',
    'Einbindung',
    'Veröffentlichen',
  ]);
  await expect(tabs.getByRole('link', { name: 'Übersicht' })).toHaveAttribute(
    'aria-current',
    'page',
  );
  await tabs.getByRole('link', { name: 'Aufbewahrung' }).click();
  await expect(page).toHaveURL(`/t/${A}/f/${FA}/storage`);
  await expect(tabs.getByRole('link', { name: 'Aufbewahrung' })).toHaveAttribute(
    'aria-current',
    'page',
  );
  await page.goBack();
  await expect(page).toHaveURL(`/t/${A}/f/${FA}`);
});

test.describe('Mobil (320 px)', () => {
  test.use({ viewport: { width: 320, height: 700 } });
  test('Menü als Sheet: Fokus auf dem ersten Eintrag, Escape gibt den Fokus zurück, schließt nach Navigation', async ({
    page,
  }) => {
    await mock(page);
    await page.goto('/overview');
    const trigger = page.getByRole('button', { name: 'Navigation öffnen' });
    await trigger.click();
    const sheet = page.getByRole('dialog', { name: 'Hauptnavigation' });
    await expect(sheet).toBeVisible();
    await expect(sheet.getByRole('link', { name: 'Übersicht', exact: true })).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(sheet).toBeHidden();
    await expect(trigger).toBeFocused();
    await trigger.click();
    await sheet.getByRole('link', { name: 'Kunden', exact: true }).click();
    await expect(page).toHaveURL('/t');
    await expect(sheet).toBeHidden();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });
  test('Formular-Reiter rollen seitlich, die Seite scrollt nicht seitlich', async ({ page }) => {
    await mock(page);
    await page.goto(`/t/${A}/f/${FA}`);
    await expect(page.getByRole('navigation', { name: 'Bereiche des Formulars' })).toBeVisible();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });
});

test('Offline-Hinweis erscheint in der Kopfzeile', async ({ page, context }) => {
  await mock(page);
  await page.goto('/overview');
  await expect(page.getByRole('status').filter({ hasText: 'Offline' })).toHaveCount(0);
  await context.setOffline(true);
  await expect(page.getByRole('status').filter({ hasText: 'Offline' })).toBeVisible();
  await context.setOffline(false);
  await expect(page.getByRole('status').filter({ hasText: 'Offline' })).toHaveCount(0);
});

test('G dann B öffnet die Bereichsauswahl, die Palette bietet Schlüssel entsperren', async ({
  page,
}) => {
  await mock(page);
  await page.goto('/overview');
  await expect(page.getByTestId('area-trigger')).toBeVisible();
  await page.keyboard.press('g');
  await page.keyboard.press('b');
  await expect(page.getByRole('listbox', { name: 'Bereiche' })).toBeVisible();
  await page.keyboard.press('Escape');
  await page.keyboard.press('Control+k');
  await expect(page.getByRole('option', { name: /Schlüssel entsperren/ })).toBeVisible();
});
