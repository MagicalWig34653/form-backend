import { writeFileSync } from 'node:fs';
import { test, expect, type Page } from '@playwright/test';
import {
  addAuthenticator,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';

// Legacy API end to end (orchestrated by backend/e2e-legacy.sh): this spec only prepares a published form with a required field
// in the real UI and hands its UUID over; the OLD PHP SDK of the previous backend is then run against the public listener by the script.

async function addRequiredField(page: Page, name: string, label: string, kind: string) {
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Technischer Name').fill(name);
  await page.getByLabel('Beschriftung').fill(label);
  await page.getByLabel('Art').selectOption(kind);
  await page.getByLabel('Pflichtfeld').check();
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByText(label, { exact: true }).first()).toBeVisible();
}

test('Legacy API: publish a form for the old SDK', async ({ page, context }) => {
  test.setTimeout(240_000);
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  await createCustomer(page, 'Alt-SDK Kunde');
  const form = await createForm(page, 'Alt-SDK Kontakt');
  await page.getByRole('link', { name: 'Felder', exact: true }).click();
  await addRequiredField(page, 'name', 'Name', 'text');
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Technischer Name').fill('email');
  await page.getByLabel('Beschriftung').fill('E-Mail');
  await page.getByLabel('Art').selectOption('email');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByText('E-Mail', { exact: true }).first()).toBeVisible();
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
  writeFileSync(env('E2E_FORM_FILE'), form);
});
