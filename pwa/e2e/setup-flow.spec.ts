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
  passkeys: number;
  tokens: { id: string; label: string; expires_at: number; revoked_at: number | null }[];
  entries: number;
  /** Paths answered with a server error. */
  broken: string[];
}
function world(): World {
  return {
    connections: [],
    origin: '',
    tenants: [],
    forms: [],
    completed: false,
    recovery: true,
    passkeys: 1,
    tokens: [],
    entries: 0,
    broken: [],
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
    if (w.broken.includes(p)) return r.fulfill(j({ error: 'boom' }, 500));
    if (p === '/me/passkeys')
      return r.fulfill(
        j({
          items: Array.from({ length: w.passkeys }, (_, i) => ({
            credentialId: `p${i}`,
            label: `Gerät ${i}`,
            createdAt: '2026-01-01T00:00:00Z',
            unlocksKeys: true,
          })),
        }),
      );
    if (p === '/account/tokens' && post) {
      w.tokens.push({ id: 't1', label: 'CI', expires_at: 9e9, revoked_at: null });
      return r.fulfill(j({ token: 'x' }, 201));
    }
    if (p === '/account/tokens') return r.fulfill(j({ items: w.tokens }));
    if (p === `/tenants/${T}/forms/${F}/entries`)
      return r.fulfill(
        j({
          items: Array.from({ length: w.entries }, (_, i) => ({
            id: `e${i}`,
            receivedAt: null,
            state: 'stored',
            releaseId: 'r1',
            keyId: null,
            held: false,
          })),
          nextCursor: null,
        }),
      );
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
  test('Start führt einmal in die Einrichtung; zehn echte Schritte, Status aus den Daten', async ({
    page,
  }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/overview');
    await expect(page).toHaveURL(/\/installation$/);
    await expect(page.getByRole('heading', { level: 1, name: 'Einrichtung' })).toBeFocused();
    await expect(page.getByLabel('Einrichtungsschritte').getByRole('listitem')).toHaveCount(10);
    await expect(step(page, 'account')).toHaveAttribute('data-state', 'done');
    await expect(step(page, 'recovery')).toHaveAttribute('data-state', 'done');
    await expect(step(page, 'mail')).toHaveAttribute('data-state', 'open');
    await expect(step(page, 'customer')).toHaveAttribute('data-state', 'open');
    // Erster offener Schritt ist markiert, Seitenleiste führt die Einrichtung.
    await expect(page.locator('[aria-current="step"]')).toHaveAttribute(
      'data-testid',
      'step-passkeys',
    );
    await expect(page.getByText('2 von 10 Schritten erledigt')).toBeVisible();
    await expect(
      page.getByRole('link', { name: 'Einrichtung fortsetzen (2 von 10)' }),
    ).toBeVisible();
    // Kein Zurückspringen: Zurück führt nicht in die Weiterleitungsschleife.
    await page.goBack();
    await expect(page).not.toHaveURL(/\/installation$/);
  });

  test('Verbindung: Hinweg, Leiste, Neuladen mit Kontext, Erledigt, Rückweg', async ({ page }) => {
    const w = world();
    w.passkeys = 2;
    await mock(page, w);
    await page.goto('/installation');
    await step(page, 'mail').getByRole('button', { name: 'Verbindung anlegen' }).click();
    await expect(page).toHaveURL(/\/connections$/);
    await expect(bar(page)).toContainText(
      'Einrichtung · Schritt 5 von 10: Mail-Versandweg einrichten',
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
    await expect(bar(page)).toContainText('Schritt 4 von 10: Adressen und Einstellungen prüfen');
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
      'Schritt 7 von 10: Erstes Formular anlegen und veröffentlichen',
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
    for (const id of ['passkeys', 'token', 'testEntry', 'migration'])
      await step(page, id).getByRole('button', { name: 'Später' }).click();
    await page.getByRole('button', { name: 'Einrichtung abschließen' }).click();
    await expect(
      page.getByRole('heading', { name: 'Die Einrichtung ist abgeschlossen' }),
    ).toBeVisible();
    // Zusammenfassung: erledigt und übersprungen mit direkten Links.
    const sum = page.getByTestId('setup-summary');
    await expect(sum).toContainText('6 von 10 Schritten erledigt');
    await expect(sum.getByRole('link')).toHaveCount(4);
    await expect(sum.getByRole('link', { name: /Probe-Einsendung prüfen/ })).toHaveAttribute(
      'href',
      `/t/${T}/f/${F}/entries`,
    );
    await sum.getByRole('link', { name: /API-Token für Anbindungen anlegen/ }).click();
    await expect(page).toHaveURL(/\/api-tokens$/);
    await page.goBack();
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

/** The three optional steps: hint -> target page -> return -> progress, "Später", error case, 320 px, axe. */
test.describe('Weitere Schritte: Passkeys, Token, Probe-Einsendung', () => {
  const published = (w: World) => {
    w.tenants.push({ id: T, name: 'Kunde', permissions: ['form.read'] });
    w.forms.push({ id: F, name: 'Kontakt', active: true, currentReleaseId: 'r1' });
  };
  const refocus = (page: Page) => page.evaluate(() => window.dispatchEvent(new Event('focus')));

  test('Passkeys: erst ab zwei erledigt; Hinweis, Konto-Seite, Rückkehr, Fortschritt', async ({
    page,
  }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/installation');
    const s = step(page, 'passkeys');
    await expect(s).toHaveAttribute('data-state', 'open');
    await expect(s).toContainText('optional');
    await expect(s).toContainText('sperren Sie sich aus');
    await s.getByRole('button', { name: 'Passkey hinzufügen' }).click();
    await expect(page).toHaveURL(/\/account$/);
    await expect(bar(page)).toContainText('Schritt 3 von 10: Zweiten Passkey');
    w.passkeys = 2;
    await refocus(page);
    await expect(bar(page).getByRole('status')).toContainText('Dieser Schritt ist erledigt');
    await bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }).click();
    await expect(step(page, 'passkeys')).toHaveAttribute('data-state', 'done');
    await expect(page.getByText('3 von 10 Schritten erledigt')).toBeVisible();
    await expect(
      step(page, 'passkeys').getByRole('link', { name: 'Passkeys verwalten' }),
    ).toBeVisible();
  });

  test('Passkeys: Ladefehler ist Fehler, nicht offen', async ({ page }) => {
    const w = world();
    w.broken.push('/me/passkeys');
    await mock(page, w);
    await page.goto('/installation');
    await expect(step(page, 'passkeys')).toHaveAttribute('data-state', 'error');
  });

  test('Token: PHP-SDK-Hinweis, Zielseite, nur gültige Token zählen, Rückkehr', async ({
    page,
  }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/installation');
    const s = step(page, 'token');
    await expect(s).toContainText('PHP-SDK');
    await s.getByRole('button', { name: 'API-Token anlegen' }).click();
    await expect(page).toHaveURL(/\/api-tokens$/);
    await expect(bar(page)).toContainText('Schritt 8 von 10: API-Token');
    w.tokens.push({ id: 'old', label: 'alt', expires_at: 1, revoked_at: null });
    w.tokens.push({ id: 'rev', label: 'rev', expires_at: 9e9, revoked_at: 5 });
    await refocus(page);
    await expect(bar(page).getByRole('status')).toHaveText('');
    w.tokens.push({ id: 't1', label: 'CI', expires_at: 9e9, revoked_at: null });
    await refocus(page);
    await expect(bar(page).getByRole('status')).toContainText('Dieser Schritt ist erledigt');
    await bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }).click();
    await expect(step(page, 'token')).toHaveAttribute('data-state', 'done');
  });

  test('Token: Fehlerfall, erneut prüfen, Später überlebt Neuladen', async ({ page }) => {
    const w = world();
    w.broken.push('/account/tokens');
    await mock(page, w);
    await page.goto('/installation');
    const s = step(page, 'token');
    await expect(s).toHaveAttribute('data-state', 'error');
    await expect(s).toContainText('konnte nicht ermittelt werden');
    w.broken = [];
    await s.getByRole('button', { name: 'Status neu prüfen' }).click();
    await expect(s).toHaveAttribute('data-state', 'open');
    await s.getByRole('button', { name: 'Später' }).click();
    await expect(s).toHaveAttribute('data-state', 'skipped');
    await page.reload();
    await expect(step(page, 'token')).toHaveAttribute('data-state', 'skipped');
  });

  test('Probe-Einsendung: Hinweis ohne Formular, dann Einsendungen, Rückkehr, erledigt', async ({
    page,
  }) => {
    const w = world();
    await mock(page, w);
    await page.goto('/installation');
    const s = step(page, 'testEntry');
    await expect(s).toHaveAttribute('data-state', 'open');
    await expect(s).toContainText('Veröffentlichen Sie zuerst ein Formular.');
    await expect(s.getByRole('button', { name: 'Einsendungen prüfen' })).toHaveCount(0);

    published(w);
    await page.reload();
    await s.getByRole('button', { name: 'Einsendungen prüfen' }).click();
    await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}/entries$`));
    await expect(bar(page)).toContainText('Schritt 9 von 10: Probe-Einsendung prüfen');
    await expect(bar(page).getByRole('status')).toHaveText('');
    w.entries = 1;
    await refocus(page);
    await expect(bar(page).getByRole('status')).toContainText('Dieser Schritt ist erledigt');
    await bar(page).getByRole('button', { name: 'Weiter zum nächsten Schritt' }).click();
    await expect(step(page, 'testEntry')).toHaveAttribute('data-state', 'done');
    await expect(
      step(page, 'testEntry').getByRole('link', { name: 'Einsendungen ansehen' }),
    ).toBeVisible();
  });

  test('Probe-Einsendung: Listenfehler ist Fehler, nicht offen; Später', async ({ page }) => {
    const w = world();
    published(w);
    w.broken.push(`/tenants/${T}/forms/${F}/entries`);
    await mock(page, w);
    await page.goto('/installation');
    const s = step(page, 'testEntry');
    await expect(s).toHaveAttribute('data-state', 'error');
    w.broken = [];
    await s.getByRole('button', { name: 'Status neu prüfen' }).click();
    await expect(s).toHaveAttribute('data-state', 'open');
    await s.getByRole('button', { name: 'Später' }).click();
    await expect(s).toHaveAttribute('data-state', 'skipped');
  });

  test('320 px und axe mit neuen Schritten und Zusammenfassung, Screenshots', async ({
    page,
  }, info) => {
    const w = world();
    published(w);
    w.connections.push({ id: 'c1', name: 'Mail', kind: 'smtp', enabled: true });
    w.origin = 'https://example.org';
    await mock(page, w);
    await page.setViewportSize({ width: 320, height: 700 });
    await page.goto('/installation');
    await expect(step(page, 'testEntry')).toBeVisible();
    await page.screenshot({ path: info.outputPath('schritte-320.png'), fullPage: true });
    const overflow = () =>
      page.evaluate(
        () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
      );
    expect(await overflow()).toBe(false);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    for (const id of ['passkeys', 'token', 'testEntry', 'migration'])
      await step(page, id).getByRole('button', { name: 'Später' }).click();
    await page.getByRole('button', { name: 'Einrichtung abschließen' }).click();
    await expect(page.getByTestId('setup-summary')).toBeVisible();
    await page.screenshot({ path: info.outputPath('zusammenfassung-320.png'), fullPage: true });
    expect(await overflow()).toBe(false);
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
    await page.emulateMedia({ colorScheme: 'dark' });
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  });
});
