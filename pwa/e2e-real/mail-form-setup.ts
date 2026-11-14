import { writeFileSync } from 'node:fs';
import { expect, type BrowserContext, type Page } from '@playwright/test';
import {
  addAuthenticator,
  addField,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';

// Shared setup of the mail end-to-ends: customer, form with three fields, SMTP connection to Mailpit, published, credentials file.
// Same clicks as real-mail-resilience.spec.ts. Synthetic data only.

async function publish(page: Page) {
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel(/Ich habe (den Entwurf|die Änderungen) geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
}

export async function setupMailForm(
  page: Page,
  context: BrowserContext,
): Promise<{ credentials: string; formId: string }> {
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  await createCustomer(page, 'E2E Kunde');
  await createForm(page, 'Kontakt');
  await page.getByRole('link', { name: 'Felder', exact: true }).click();
  await addField(page, 'email', 'E-Mail', 'email');
  await addField(page, 'vorname', 'Vorname', 'text');
  await addField(page, 'anliegen', 'Anliegen', 'text');
  const formUrl = /^(.*\/f\/[0-9a-f-]{36})/.exec(new URL(page.url()).pathname)![1]!;

  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Verbindung anlegen' }).first().click();
  await page.getByLabel('Name', { exact: true }).fill('Mailpit');
  await page.getByLabel('Server').fill('127.0.0.1');
  await page.getByLabel('Port').fill(env('E2E_MAILPIT_SMTP'));
  await page.locator('#conn-security').selectOption('plain');
  await page.getByRole('button', { name: 'Verbindung anlegen' }).last().click();
  await expect(page.getByText('Die Verbindung wurde angelegt.')).toBeVisible();
  await page.getByRole('button', { name: 'Aktionen für Mailpit' }).click();
  await page.getByRole('menuitem', { name: 'Kunden zuweisen' }).click();
  await page.getByLabel('E2E Kunde').check();
  await page.getByRole('button', { name: 'Zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();

  await page.goto(`${formUrl}/mail`);
  await page.getByLabel('Versandverbindung').selectOption({ label: 'Mailpit (SMTP-Server)' });
  await page.getByRole('button', { name: 'Versandweg zuweisen' }).click();
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('formular@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await expect(page.locator('#org-content option:checked')).toHaveText('Mit allen Angaben');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await publish(page);

  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const credentials = `${env('E2E_TMP')}/credentials.json`;
  writeFileSync(credentials, file, { mode: 0o600 });
  return { credentials, formId: (JSON.parse(file) as { formId: string }).formId };
}
