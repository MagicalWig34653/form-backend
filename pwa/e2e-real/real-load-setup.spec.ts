import { writeFileSync } from 'node:fs';
import { test, expect } from '@playwright/test';
import {
  addAuthenticator,
  configureAndPublish,
  env,
  createCustomer,
  createForm,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';

// Provisions one customer/form through the real UI and writes the SDK setup file for backend/loadtest.sh
// (E2E_CREDENTIALS_OUT). Synthetic data only.

test('provision a form and write SDK credentials for the load probe', async ({ page, context }) => {
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  // Customer, form and fields through the real UI with the keyring unlocked by the PRF passkey.
  await createCustomer(page, 'E2E Kunde');
  await createForm(page, 'Kontakt');
  await configureAndPublish(page, [
    ['email', 'E-Mail', 'email'],
    ['vorname', 'Vorname', 'text'],
  ]);
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const creds = JSON.parse(file) as Record<string, string>;
  expect(creds.signingSeed).toMatch(/^[A-Za-z0-9_-]{43}$/);
  writeFileSync(env('E2E_CREDENTIALS_OUT'), file, { mode: 0o600 });
});
