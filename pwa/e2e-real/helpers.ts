import { expect, type BrowserContext, type Page } from '@playwright/test';

// Shared steps for the real end-to-end specs (real binary, throwaway DB, CDP virtual authenticator with PRF).
export const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

export async function addAuthenticator(page: Page, context: BrowserContext) {
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
      // E2E_NO_PRF=1: a passkey that cannot derive key material (older browsers, some password managers)
      hasPrf: process.env.E2E_NO_PRF !== '1',
    },
  });
}

/** Opens the enrollment link and registers the passkey. */
export async function registerPasskey(page: Page, link: string) {
  await page.goto(link);
  await expect(page).toHaveURL(/\/setup$/); // the token left the address bar
  expect(await page.evaluate(() => window.location.hash)).toBe('');
  await page.getByLabel('Name des Geräts').fill('E2E-Gerät');
  await page.getByRole('button', { name: 'Passkey erstellen' }).click();
  await expect(page.getByText('Der Passkey wurde eingerichtet.')).toBeVisible();
}

/** Passkey login and recovery code; the setup assistant is shown afterwards. */
export async function loginAndSecure(page: Page): Promise<string> {
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
  await expect(page.getByRole('heading', { name: 'Einrichtung', exact: true })).toBeVisible();
  return code;
}

export async function toOverview(page: Page) {
  await page.getByRole('link', { name: 'Übersicht', exact: true }).first().click();
}

/** Creates a customer from the overview and opens it. Returns its UUID. */
export async function createCustomer(page: Page, name: string): Promise<string> {
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('button', { name: 'Kunde anlegen', exact: true }).click();
  await page.getByLabel('Name des Kunden').fill(name);
  await page.getByRole('button', { name: 'Kunde anlegen', exact: true }).last().click();
  await page.getByRole('link', { name: `Öffnen: ${name}` }).click();
  await expect(page).toHaveURL(/\/t\/[0-9a-f-]{36}/);
  return /\/t\/([0-9a-f-]{36})/.exec(page.url())![1];
}

/** Creates a form in the open customer. Returns its UUID. */
export async function createForm(page: Page, name: string): Promise<string> {
  await page.getByRole('button', { name: 'Formular anlegen', exact: true }).click();
  await page.getByLabel('Name des Formulars').fill(name);
  await page.getByRole('button', { name: 'Formular anlegen', exact: true }).last().click();
  await expect(page.getByRole('heading', { name, exact: true })).toBeVisible();
  return /\/f\/([0-9a-f-]{36})/.exec(page.url())![1];
}

export async function addField(page: Page, name: string, label: string, kind: string) {
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Technischer Name').fill(name);
  await page.getByLabel('Beschriftung').fill(label);
  await page.getByLabel('Art').selectOption(kind);
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByText(label, { exact: true }).first()).toBeVisible();
}

/** Opens the configuration of the open form, adds the fields and publishes. */
export async function configureAndPublish(page: Page, fields: [string, string, string][]) {
  await page.getByRole('link', { name: 'Felder', exact: true }).click();
  for (const [name, label, kind] of fields) await addField(page, name, label, kind);
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
}
