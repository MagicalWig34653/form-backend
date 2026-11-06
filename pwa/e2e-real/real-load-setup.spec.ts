import { writeFileSync } from 'node:fs';
import { test, expect } from '@playwright/test';

// Provisions one customer/form through the real UI and writes the SDK setup file for backend/loadtest.sh
// (E2E_CREDENTIALS_OUT). Synthetic data only.
const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

test('provision a form and write SDK credentials for the load probe', async ({ page, context }) => {
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

  // Customer, form and fields through the real UI with the keyring unlocked by the PRF passkey.
  await page.getByRole('button', { name: 'Zum Überblick' }).click();
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('button', { name: 'Kunde anlegen', exact: true }).click();
  await page.getByLabel('Name des Kunden').fill('E2E Kunde');
  await page.getByRole('button', { name: 'Kunde anlegen', exact: true }).last().click();
  await page.getByRole('link', { name: /Öffnen: E2E Kunde/ }).click();
  await page.getByRole('button', { name: 'Formular anlegen', exact: true }).click();
  await page.getByLabel('Name des Formulars').fill('Kontakt');
  await page.getByRole('button', { name: 'Formular anlegen', exact: true }).last().click();
  await expect(page.getByRole('heading', { name: 'Kontakt', exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Konfiguration', exact: true }).click();
  async function addField(name: string, label: string, kind: string) {
    await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
    await page.getByLabel('Technischer Name').fill(name);
    await page.getByLabel('Beschriftung').fill(label);
    await page.getByLabel('Art').selectOption(kind);
    await page.getByRole('button', { name: 'Speichern', exact: true }).click();
    await expect(page.getByText(label, { exact: true }).first()).toBeVisible();
  }
  await addField('email', 'E-Mail', 'email');
  await addField('vorname', 'Vorname', 'text');
  await page.getByRole('link', { name: 'Prüfen & veröffentlichen' }).click();
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Einrichtungsdatei ausstellen' }).click();
  const file = await page.getByLabel('Einrichtungsdatei', { exact: true }).inputValue();
  const creds = JSON.parse(file) as Record<string, string>;
  expect(creds.signingSeed).toMatch(/^[A-Za-z0-9_-]{43}$/);
  writeFileSync(env('E2E_CREDENTIALS_OUT'), file, { mode: 0o600 });
});
