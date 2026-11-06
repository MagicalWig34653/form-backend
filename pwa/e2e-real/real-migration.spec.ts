import { test, expect } from '@playwright/test';

// First administrator from the operator command: enrollment link -> real passkey registration (CDP virtual authenticator)
// -> passkey login -> password. Orchestrated by backend/e2e-setup.sh (it runs `bootstrap-admin` and passes the link).
const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

test('migration: real legacy dump through the Umstieg UI (source check)', async ({
  page,
  context,
}) => {
  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
      hasPrf: true,
    },
  });

  await page.goto(env('E2E_SETUP_LINK'));
  await expect(page).toHaveURL(/\/setup$/); // the token left the address bar
  expect(await page.evaluate(() => window.location.hash)).toBe('');
  await page.getByLabel('Name des Geräts').fill('E2E-Gerät');
  await page.getByRole('button', { name: 'Passkey erstellen' }).click();
  await expect(page.getByText('Der Passkey wurde eingerichtet.')).toBeVisible();

  await page.goto('/login');
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  // First login: the account is asked to secure its recovery code before anything else (ADR 0024).
  await expect(page.getByRole('heading', { name: 'Wiederherstellungscode sichern' })).toBeVisible();
  await page.getByRole('button', { name: 'Wiederherstellungscode vorbereiten' }).click();
  const shown = page.getByText(/^[A-Z0-9]{4}(?:-[A-Z0-9]{4}){7}$/);
  await expect(shown).toBeVisible();
  const code = (await shown.innerText()).trim();
  await page.getByLabel('Code zur Bestätigung erneut eingeben').fill(code);
  await page.getByRole('button', { name: 'Code gesichert' }).click();
  await expect(
    page.getByRole('heading', { name: 'Ihr Administrationskonto einrichten' }),
  ).toBeVisible();
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
  await page.getByLabel('Host', { exact: true }).fill('127.0.0.1');
  await page.getByLabel('Port', { exact: true }).fill(env('E2E_LEGACY_PORT'));
  await page.getByLabel('Datenbank', { exact: true }).fill(env('E2E_LEGACY_DB'));
  await page.getByLabel('Benutzer', { exact: true }).fill(env('E2E_LEGACY_USER'));
  await page.getByLabel('Passwort', { exact: true }).fill(env('E2E_LEGACY_PASSWORD'));
  await page.getByLabel('TLS-Modus').selectOption('disable');
  await page.getByRole('button', { name: 'Verbindung prüfen' }).click();
  await expect(page.getByText(/Nur lesender Zugang geprüft/)).toBeVisible();

  // Single customer: the form is prefilled from the inventory; only the customer name and namespace are typed.
  await page.getByLabel('Kundenname').fill('Kubus');
  await page.getByLabel('Quellnamespace').fill('kubus');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText(/Prüflauf: (Wartet auf Prüfung|Fehlgeschlagen)/)).toBeVisible({
    timeout: 90_000,
  });
  await page.getByText('Probleme ansehen und bestätigte Zähler').click();
  await page.waitForTimeout(800);
  // Dry-run report: the real dump imports 3 forms, 28 fields and 10 submissions (the latter flagged for review).
  const report = page.locator('pre').last();
  await expect(report).toContainText('"importedCount": 28');
  await expect(report).toContainText('"cutoverReady": false');
});
