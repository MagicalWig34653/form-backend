import { test, expect, type Page } from '@playwright/test';

const A = 'aaaaaaaa-1111-4111-8111-11111111111a';
const B = 'bbbbbbbb-1111-4111-8111-11111111111b';
const F1 = '11111111-1111-4111-8111-111111111111';
const F2 = '22222222-2222-4222-8222-222222222222';
const F3 = '33333333-3333-4333-8333-333333333333';

interface Options {
  /** The form list of customer B fails. */
  failB?: boolean;
  /** Extra forms for customer A (search field needs many entries). */
  extraForms?: number;
}
async function mock(page: Page, o: Options = {}) {
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  const listCalls: string[] = [];
  const formsOf = (tenant: string) =>
    tenant === A
      ? [
          { id: F1, name: 'Kontakt', active: true, currentReleaseId: 'r1' },
          { id: F2, name: 'Angebot', active: true, currentReleaseId: 'r2' },
          ...Array.from({ length: o.extraForms ?? 0 }, (_, i) => ({
            id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
            name: `Zusatz ${i + 1}`,
            active: true,
            currentReleaseId: 'r3',
          })),
        ]
      : [{ id: F3, name: 'Anfrage', active: true, currentReleaseId: 'r4' }];
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: false }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            { id: A, name: 'Kunde A', permissions: ['form.read'] },
            { id: B, name: 'Kunde B', permissions: ['form.read'] },
          ],
        }),
      );
    const list = /^\/tenants\/([^/]+)\/forms$/.exec(p);
    if (list) {
      const tenant = list[1] as string;
      listCalls.push(tenant);
      if (tenant === B && o.failB) return r.fulfill(j({ type: 'x' }, 500));
      return r.fulfill(j({ items: formsOf(tenant), nextCursor: null }));
    }
    const one = /^\/tenants\/([^/]+)\/forms\/([^/]+)(\/.*)?$/.exec(p);
    if (one) {
      const [, tenant, id, rest] = one;
      const form = formsOf(tenant as string).find((f) => f.id === id);
      if (rest === '/statistics')
        return r.fulfill(
          j({
            from: '2026-10-03',
            to: '2026-11-01',
            total: 5,
            visits: 20,
            begins: 12,
            submits: 5,
            abandons: 3,
            conversion: 0.25,
            days: [
              {
                date: '2026-11-01',
                count: 5,
                visits: 20,
                begins: 12,
                submits: 5,
                abandons: 3,
                conversion: 0.25,
              },
            ],
          }),
        );
      if (rest === '/entries')
        return r.fulfill(
          j({
            items: [
              {
                id: `e-${id}`,
                receivedAt: '2026-11-01T10:00:00Z',
                state: 'accepted',
                releaseId: null,
                keyId: null,
                held: false,
              },
            ],
            nextCursor: null,
          }),
        );
      if (!rest && form)
        return r.fulfill(
          j({
            ...form,
            currentReleaseVersion: 1,
            draftIds: [],
            mailConnectionId: 'm',
          }),
        );
    }
    return r.fulfill(j({ items: [] }));
  });
  return listCalls;
}

const trigger = (page: Page) => page.getByTestId('area-trigger');
const listbox = (page: Page) => page.getByRole('listbox', { name: 'Bereiche' });

test('Gesamt: Dashboard über alle Kunden mit Kennzahlen und letzten Einsendungen', async ({
  page,
}) => {
  await mock(page);
  await page.goto('/overview');
  await expect(trigger(page)).toContainText('Gesamt');
  await expect(page.getByTestId('kpi-grid')).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Gesamtübersicht' })).toBeVisible();
  const recent = page.locator('#recent-entries');
  await expect(recent).toContainText('Kunde A · Kontakt');
  await expect(recent).toContainText('Kunde B · Anfrage');
  // Summe über die drei Formulare: 3 x 5 Einsendungen.
  await expect(page.getByTestId('kpi-grid')).toContainText('15');
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
  await expect(nav.getByRole('link', { name: 'Einsendungen', exact: true })).toHaveAttribute(
    'href',
    '/overview#recent-entries',
  );
  await expect(nav.getByRole('link', { name: 'Statistik', exact: true })).toHaveAttribute(
    'href',
    '/overview#statistics',
  );
  // Die Kundenliste bleibt erreichbar.
  await nav.getByRole('link', { name: 'Kunden', exact: true }).click();
  await expect(page).toHaveURL('/t');
  await expect(page.getByRole('heading', { name: 'Kunden', exact: true })).toBeVisible();
  await expect(trigger(page)).toContainText('Gesamt');
});

test('Auswahl: Gesamt, Kunde, Formular; Formular-Reiter nur im Formular', async ({ page }) => {
  await mock(page);
  await page.goto('/overview');
  await trigger(page).click();
  await expect(listbox(page)).toBeVisible();
  await expect(page.getByRole('option', { name: /^Gesamt/ })).toHaveAttribute(
    'aria-selected',
    'true',
  );
  await expect(page.getByRole('option', { name: 'Kontakt' })).toBeVisible();
  await expect(page.getByRole('group', { name: 'Kunde B' }).getByRole('option')).toHaveCount(2);
  await page.getByRole('option', { name: 'Kunde A', exact: true }).click();
  await expect(page).toHaveURL(`/t/${A}`);
  await expect(trigger(page)).toContainText('Kunde A');
  await expect(page.getByRole('link', { name: 'Einbindung', exact: true })).toHaveCount(0);
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
  await expect(nav.getByRole('link', { name: 'Einsendungen', exact: true })).toHaveAttribute(
    'href',
    `/t/${A}#recent-entries`,
  );

  await trigger(page).click();
  await page.getByRole('option', { name: 'Angebot' }).click();
  await expect(page).toHaveURL(`/t/${A}/f/${F2}`);
  await expect(trigger(page)).toContainText('Angebot');
  await expect(trigger(page)).toContainText('Kunde A');
  await expect(page.getByRole('link', { name: 'Einbindung', exact: true }).first()).toBeVisible();
  await expect(nav.getByRole('link', { name: 'Einsendungen', exact: true })).toHaveAttribute(
    'href',
    `/t/${A}/f/${F2}/entries`,
  );

  await trigger(page).click();
  await page.getByRole('option', { name: /^Gesamt/ }).click();
  await expect(page).toHaveURL('/overview');
  await expect(page.getByRole('link', { name: 'Einbindung', exact: true })).toHaveCount(0);
});

test('Tastatur: Pfeile, Enter, Escape gibt den Fokus zurück', async ({ page }) => {
  await mock(page);
  await page.goto('/overview');
  await trigger(page).focus();
  await page.keyboard.press('ArrowDown');
  await expect(listbox(page)).toBeFocused();
  await expect(trigger(page)).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('Escape');
  await expect(listbox(page)).toHaveCount(0);
  await expect(trigger(page)).toBeFocused();

  await page.keyboard.press('Enter');
  await expect(listbox(page)).toBeFocused();
  // Gesamt ist gewählt; ArrowDown -> Kunde A.
  await page.keyboard.press('ArrowDown');
  await expect(listbox(page)).toHaveAttribute('aria-activedescendant', new RegExp(`area-${A}$`));
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(`/t/${A}/f/${F2}`);
  await expect(listbox(page)).toHaveCount(0);
});

test('Fehler eines Kunden wird einzeln angezeigt, ohne erfundene Werte', async ({ page }) => {
  await mock(page, { failB: true });
  await page.goto('/overview');
  await expect(page.getByTestId('overview-problems')).toContainText(
    'Formulare von Kunde B konnten nicht geladen werden.',
  );
  // Die Kunden mit geladener Liste zählen weiter.
  await expect(page.locator('#recent-entries')).toContainText('Kunde A · Kontakt');
  await expect(page.locator('#recent-entries')).not.toContainText('Anfrage');
  await trigger(page).click();
  await expect(page.getByRole('option', { name: /Kunde B/ })).toContainText(
    'Formulare dieses Kunden konnten nicht geladen werden.',
  );
  // Der Kunde selbst bleibt wählbar.
  await page.getByRole('option', { name: /Kunde B/ }).click();
  await expect(page).toHaveURL(`/t/${B}`);
});

test('Suchfeld erst bei vielen Einträgen, Filter nach Kunde und Formular', async ({ page }) => {
  await mock(page, { extraForms: 8 });
  await page.goto('/overview');
  await trigger(page).click();
  const search = page.getByRole('combobox', { name: 'Bereich suchen' });
  await expect(search).toBeFocused();
  await search.fill('zusatz 3');
  await expect(page.getByRole('option')).toHaveCount(2);
  await expect(page.getByRole('option', { name: 'Zusatz 3' })).toBeVisible();
  await search.fill('qqq');
  await expect(page.getByText('Kein Bereich gefunden.')).toBeVisible();
  await search.fill('zusatz 3');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(/\/f\/00000000-0000-4000-8000-000000000002$/);
});

test('Formularlisten werden nur beim Öffnen geladen und gecacht', async ({ page }) => {
  const calls = await mock(page);
  await page.goto(`/t/${A}`);
  await expect(page.getByTestId('kpi-grid')).toBeVisible();
  const before = calls.length;
  await trigger(page).click();
  await expect(page.getByRole('option', { name: /Kunde B/ })).toBeVisible();
  await expect(page.getByRole('option', { name: 'Anfrage' })).toBeVisible();
  expect(calls.filter((c) => c === B)).toHaveLength(1);
  await page.keyboard.press('Escape');
  await trigger(page).click();
  await expect(page.getByRole('option', { name: 'Anfrage' })).toBeVisible();
  expect(calls.filter((c) => c === B)).toHaveLength(1);
  expect(calls.length).toBeGreaterThanOrEqual(before);
});

test.describe('mobil', () => {
  test.use({ viewport: { width: 390, height: 800 } });
  test('Auswahl im Drawer schließt ihn nach der Navigation', async ({ page }) => {
    await mock(page);
    await page.goto('/overview');
    await page.getByRole('button', { name: 'Navigation öffnen' }).click();
    await trigger(page).click();
    await expect(page.getByRole('option', { name: 'Kunde B', exact: true })).toBeVisible();
    await page.getByRole('option', { name: 'Kunde B', exact: true }).click();
    await expect(page).toHaveURL(`/t/${B}`);
    await expect(page.getByRole('dialog', { name: 'Hauptnavigation' })).toBeHidden();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });
  test('Escape schließt zuerst die Auswahl, dann den Drawer', async ({ page }) => {
    await mock(page);
    await page.goto('/overview');
    await page.getByRole('button', { name: 'Navigation öffnen' }).click();
    await trigger(page).click();
    await expect(listbox(page)).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(listbox(page)).toHaveCount(0);
    await expect(page.getByRole('dialog', { name: 'Hauptnavigation' })).toBeVisible();
  });
});
