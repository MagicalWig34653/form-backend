import { test, expect } from '@playwright/test';
import {
  addAuthenticator,
  configureAndPublish,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';
import {
  expectReadable,
  importState,
  issueCredentials,
  legacyKey,
  openAdvanced,
  reloadLocked,
  resetBudget,
  submit,
  unlockWithRecoveryCode,
} from './unlock-helpers';

// The same unlock ways with a passkey that delivers NO PRF output (E2E_NO_PRF=1, virtual authenticator without hasPrf):
// the account key is protected by the account recovery code only. Orchestrated by backend/e2e-unlock.sh.
test('unlock without PRF: account recovery code, imported customer key, legacy key', async ({
  page,
  context,
}) => {
  test.setTimeout(300_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  const accountCode = await loginAndSecure(page);
  await toOverview(page);

  console.log('STEP customer created in the new system');
  await createCustomer(page, 'A Kunde');
  await createForm(page, 'Kontakt A');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  const credA = await issueCredentials(page);
  const marker = 'MARKER-NEU-' + Math.random().toString(36).slice(2, 8);
  submit(credA, 'a-1', marker);
  await expectReadable(page, 'A Kunde', 'Kontakt A', marker);
  await reloadLocked(page);

  console.log('STEP passkey unlock offered although the passkey has no PRF');
  await openAdvanced(page);
  await page.getByRole('button', { name: 'Mit Passkey entsperren' }).first().click();
  // The reason must be named: the passkey cannot unlock, the recovery code can (not a generic failure).
  await expect(page.getByRole('alert').filter({ hasText: /Wiederherstellungscode/ })).toBeVisible();
  await unlockWithRecoveryCode(page, accountCode);
  await expectReadable(page, 'A Kunde', 'Kontakt A', marker);

  console.log('STEP imported customer, legacy key');
  resetBudget();
  await page.getByRole('link', { name: 'Übersicht', exact: true }).first().click();
  await createCustomer(page, 'B Kunde (Umstieg)');
  const tenantB = /\/t\/([0-9a-f-]{36})/.exec(page.url())![1];
  await createForm(page, 'Kontakt B');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  const old = legacyKey('KM4T-8WQP-X7HN-2DVR-6JGC-9BZY-3FSE-5ULA');
  importState(tenantB, old);
  const credB = await issueCredentials(page);
  const markerOld = 'MARKER-ALT-' + Math.random().toString(36).slice(2, 8);
  submit(credB, 'b-1', markerOld);
  await page.getByRole('link', { name: 'Formulare', exact: true }).first().click();
  await page
    .getByRole('link', { name: /Kontakt B/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await page.getByRole('button', { name: 'Altschlüssel übernehmen' }).click();
  await page.locator(`#legacy-key-${tenantB}`).fill(old.secret.toString('base64url'));
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).nth(1).click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
  await expectReadable(page, 'B Kunde (Umstieg)', 'Kontakt B', markerOld);

  console.log('STEP after a reload the account recovery code opens both customers');
  await reloadLocked(page);
  await unlockWithRecoveryCode(page, accountCode);
  await expectReadable(page, 'A Kunde', 'Kontakt A', marker);
  await expectReadable(page, 'B Kunde (Umstieg)', 'Kontakt B', markerOld);
});
