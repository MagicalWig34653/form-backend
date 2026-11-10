import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';

/** Stateful server double: the checklist reads these facts, the test changes them like a real action would. */
interface World {
  connections: { id: string; name: string; kind: string; enabled: boolean }[];
  origin: string;
  tenants: { id: string; name: string; permissions: string[] }[];
  forms: { id: string; name: string; active: boolean; currentReleaseId: string | null }[];
  completed: boolean;
  recovery: boolean;
}
function world(): World {
  return {
    connections: [],
    origin: '',
    tenants: [],
    forms: [],
    completed: false,
    recovery: true,
  };
}

async function mock(page: Page, w: World) {
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  await page.route('**/admin/api/v1/**', async (r) => {
    const req = r.request();
    const p = new URL(req.url()).pathname.replace('/admin/api/v1', '');
    const post = req.method() === 'POST';
    if (p === '/auth/session')
      return r.fulfill(j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a' }));
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/setup-state')
      return r.fulfill(
        j({ required: !w.completed, migrationAllowed: true, migrationEnabled: true }),
      );
    if (p === '/me/key-bundle')
      return r.fulfill(
        j({
          rpId: 'localhost',
          accountPublicKey: 'k',
          wraps: [],
          access: [],
          recovery: w.recovery ? { at: 'x' } : null,
        }),
      );
    if (p === '/settings' && req.method() === 'PUT') {
      w.completed = true;
      return r.fulfill(j({ revision: 'r2', items: [] }));
    }
    if (p === '/settings')
      return r.fulfill(
        j({
          revision: 'r1',
          items: [
            {
              definition: { key: 'admin.origin', group: 'Hosts', type: 'origin', envName: 'X' },
              value: w.origin,
              source: 'db',
              locked: false,
            },
            {
              definition: { key: 'admin.rpID', group: 'Hosts', type: 'host', envName: 'Y' },
              value: w.origin ? 'localhost' : '',
              source: 'db',
              locked: false,
            },
          ],
        }),
      );
    if (p === '/connections' && post) {
      w.connections.push({ id: 'c1', name: 'Mail', kind: 'smtp', enabled: true });
      return r.fulfill(j({ id: 'c1' }, 201));
    }
    if (p === '/connections')
      return r.fulfill(
        j({ items: w.connections.map((c) => ({ ...c, hasCredential: false, config: {} })) }),
      );
    if (p === '/migration/jobs') return r.fulfill(j({ items: [] }));
    if (p === '/tenants' && post) {
      w.tenants.push({ id: T, name: 'Neuer Kunde', permissions: ['form.read', 'form.create'] });
      return r.fulfill(j({ id: T }, 201));
    }
    if (p === '/tenants') return r.fulfill(j({ items: w.tenants }));
    if (p === `/tenants/${T}/customer-key`) return r.fulfill(j({ publicKey: 'k' }));
    if (p === `/tenants/${T}/forms` && post) {
      w.forms.push({ id: F, name: 'Kontakt', active: false, currentReleaseId: null });
      return r.fulfill(j({ id: F }, 201));
    }
    if (p === `/tenants/${T}/forms`) return r.fulfill(j({ items: w.forms, nextCursor: null }));
    return r.fulfill(j({ items: [] }));
  });
}

const bar = (page: Page) => page.getByTestId('setup-bar');
const step = (page: Page, id: string) => page.getByTestId(`step-${id}`);

test.describe('Einrichtungsfluss', () => {
  test('Start führt einmal in die Einrichtung; sieben echte Schritte, Status aus den Daten', async ({
    page,
  }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/overview');
    await expect(page).toHaveURL(/\/installation$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Einrichtung' })).toBeFocused();
    await expect(page.getByLabel('Einrichtungsschritte').getByRole('listitem')).toHaveCount(7);
    await expect(step(page, 'account')).toHaveAttribute('data-state', 'done');
    await expect(step(page, 'recovery')).toHaveAttribute('data-state', 'done');
    await expect(step(page, 'mail')).toHaveAttribute('data-state', 'open');
    await expect(step(page, 'customer')).toHaveAttribute('data-state', 'open');
    // Erster offener Schritt ist markiert, Seitenleiste führt die Einrichtung.
    await expect(page.locator('[aria-current="step"]')).toHaveAttribute('data-testid', 'step-mail');
    await expect(page.getByText('2 von 7 Schritten erledigt')).toBeVisible();
    await expect(
      page.getByRole('link', { name: 'Einrichtung fortsetzen (2 von 7)' }),
    ).toBeVisible();
    // Kein Zurückspringen: Zurück führt nicht in die Weiterleitungsschleife.
    await page.goBack();
    await expect(page).not.toHaveURL(/\/installation$/);
  });

  test('Verbindung: Hinweg, Leiste, Neuladen mit Kontext, Erledigt, Rückweg', async ({ page }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/installation');
    await step(page, 'mail').getByRole('button', { name: 'Verbindung anlegen' }).click();
    await expect(page).toHaveURL(/\/connections$/);
    await expect(bar(page)).toContainText(
      'Einrichtung · Schritt 3 von 7: Mail-Versandweg einrichten',
    );
    await expect(bar(page).getByRole('button', { name: 'Zurück zur Einrichtung' })).toBeVisible();
    await expect(
      bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }),
    ).toHaveCount(0);

    // Neuladen: der Kontext bleibt erhalten.
    await page.reload();
    await expect(bar(page)).toBeVisible();

    // Verbindung anlegen; sobald sie existiert, bietet die Leiste den nächsten Schritt an.
    await page.locator('#conn-name').fill('Mail');
    await page.locator('#conn-host').fill('smtp.example.org');
    await page.locator('#conn-name').press('Enter');
    await expect(
      bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }),
    ).toBeVisible();
    await expect(bar(page).getByRole('status')).toContainText('Dieser Schritt ist erledigt');
    await bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }).click();
    await expect(page).toHaveURL(/\/installation$/);
    await expect(step(page, 'mail')).toHaveAttribute('data-state', 'done');
    await expect(page.locator('[aria-current="step"]')).toHaveAttribute(
      'data-testid',
      'step-addresses',
    );
    await expect(bar(page)).toHaveCount(0);
  });

  test('Einstellungen: zweite Zielseite, Rückweg ohne Erledigen, Später für Optionales', async ({
    page,
  }) => {
    const w = world();
    w.connections.push({ id: 'c1', name: 'Mail', kind: 'smtp', enabled: true });
    await mock(page, w);
    await page.goto('/installation');
    await step(page, 'addresses').getByRole('button', { name: 'Einstellungen öffnen' }).click();
    await expect(page).toHaveURL(/\/settings$/);
    await expect(bar(page)).toContainText('Schritt 4 von 7: Adressen und Einstellungen prüfen');
    // Andere Seite über die Seitenleiste: die Leiste folgt nicht.
    await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
    await expect(bar(page)).toHaveCount(0);
    await page.goto('/installation');
    await step(page, 'addresses').getByRole('button', { name: 'Später' }).click();
    await expect(step(page, 'addresses')).toHaveAttribute('data-state', 'skipped');
    await expect(page.getByText('auf später verschoben')).toBeVisible();
    // Später überlebt das Neuladen und lässt sich zurücknehmen.
    await page.reload();
    await expect(step(page, 'addresses')).toHaveAttribute('data-state', 'skipped');
    await step(page, 'addresses').getByRole('button', { name: 'Wieder aufnehmen' }).click();
    await expect(step(page, 'addresses')).toHaveAttribute('data-state', 'open');
  });

  test('Kunde und Formular inline, Veröffentlichen auf der Formularseite, Abschluss', async ({
    page,
  }) => {
    const w = world();
    w.connections.push({ id: 'c1', name: 'Mail', kind: 'smtp', enabled: true });
    w.origin = 'https://example.org';
    await mock(page, w);
    await page.goto('/installation');
    await expect(step(page, 'form').getByText('Legen Sie zuerst einen Kunden an.')).toBeVisible();
    await step(page, 'customer').getByLabel('Name des Kunden').fill('Neuer Kunde');
    await step(page, 'customer').getByRole('button', { name: 'Kunden anlegen' }).click();
    await expect(step(page, 'customer')).toHaveAttribute('data-state', 'done');
    // Inline angelegt, ohne die Einrichtung zu verlassen.
    await expect(page).toHaveURL(/\/installation$/);
    await step(page, 'form').getByLabel('Name des Formulars').fill('Kontakt');
    await step(page, 'form').getByRole('button', { name: 'Formular anlegen' }).click();
    await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}/publish$`));
    await expect(bar(page)).toContainText(
      'Schritt 6 von 7: Erstes Formular anlegen und veröffentlichen',
    );
    // Veröffentlichen (Server-Double): die Leiste bietet die Rückkehr an.
    w.forms[0]!.currentReleaseId = 'r1';
    await page.evaluate(() => window.dispatchEvent(new Event('focus')));
    await expect(
      bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }),
    ).toBeVisible();
    await bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }).click();
    await expect(page).toHaveURL(/\/installation$/);
    // Umstieg ist optional und kann auf später verschoben werden; danach ist der Abschluss möglich.
    await expect(page.getByRole('button', { name: 'Einrichtung abschließen' })).toBeDisabled();
    await step(page, 'migration').getByRole('button', { name: 'Später' }).click();
    await page.getByRole('button', { name: 'Einrichtung abschließen' }).click();
    await expect(
      page.getByRole('heading', { name: 'Die Einrichtung ist abgeschlossen' }),
    ).toBeVisible();
    await expect(page.getByRole('link', { name: /Einrichtung fortsetzen/ })).toHaveCount(0);
    await page.getByRole('button', { name: 'Zur Übersicht' }).click();
    await expect(page).toHaveURL(/\/overview$/);
  });

  test('320 px ohne Querscroll, ohne axe-Verstöße', async ({ page }) => {
    const w = world();
    await mock(page, w);
    await page.setViewportSize({ width: 320, height: 700 });
    await page.goto('/installation');
    await expect(step(page, 'mail')).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
    );
    expect(overflow).toBe(false);
    const result = await new AxeBuilder({ page }).analyze();
    expect(result.violations).toEqual([]);
    // Auch die Leiste auf einer Zielseite.
    await step(page, 'mail').getByRole('button', { name: 'Verbindung anlegen' }).click();
    await expect(bar(page)).toBeVisible();
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
      ),
    ).toBe(false);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
    await page.reload();
    await expect(bar(page)).toBeVisible();
    const dark = await new AxeBuilder({ page }).analyze();
    expect(dark.violations).toEqual([]);
  });
});
