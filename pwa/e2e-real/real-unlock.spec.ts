import { test, type Locator } from '@playwright/test';
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
  dropAccess,
  sql,
  uuidBin,
  expectReadable,
  importState,
  issueCredentials,
  legacyKey,
  openAdvanced,
  reloadLocked,
  resetBudget,
  submit,
  unlockWithPasskey,
} from './unlock-helpers';
import { expect } from '@playwright/test';

// Unlocking the customer key against the REAL backend + MariaDB with a CDP virtual authenticator with PRF
// (orchestrated by backend/e2e-unlock.sh). Covers the three ways to get at submissions:
//   1. passkey (PRF) after a reload, 2. the customer's recovery code, 3. adoption of the old private key.

test('unlock: passkey, recovery code and legacy key reach the submissions', async ({
  page,
  context,
}) => {
  test.setTimeout(300_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  console.log('STEP 1.');
  // --- 1. a customer created in the new system: passkey unlock after a reload -------------------------------------------
  await createCustomer(page, 'A Kunde');
  await createForm(page, 'Kontakt A');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  const credA = await issueCredentials(page);
  const markerNew = 'MARKER-NEU-2-' + Math.random().toString(36).slice(2, 8);
  submit(credA, 'a-2', markerNew);
  await expectReadable(page, 'A Kunde', 'Kontakt A', markerNew); // unlocked by the login
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await expectReadable(page, 'A Kunde', 'Kontakt A', markerNew);

  console.log('STEP 2.');
  // --- 2. a customer as the migration leaves it ---------------------------------------------------------------------------
  resetBudget();
  await page.getByRole('link', { name: 'Übersicht', exact: true }).first().click();
  await createCustomer(page, 'B Kunde (Umstieg)');
  const tenantB = /\/t\/([0-9a-f-]{36})/.exec(page.url())![1];
  await createForm(page, 'Kontakt B');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  resetBudget();
  const oldCode = 'KM4T-8WQP-X7HN-2DVR-6JGC-9BZY-3FSE-5ULA';
  const old = legacyKey(oldCode);
  importState(tenantB, old);
  const credB = await issueCredentials(page);
  const markerOld = 'MARKER-ALT-' + Math.random().toString(36).slice(2, 8);
  submit(credB, 'b-1', markerOld);

  console.log('STEP 2a.');
  // 2a. unlocked account key, but no access to the imported generation: the list says so and offers the way out
  await page.getByRole('link', { name: 'Formulare', exact: true }).first().click();
  await page
    .getByRole('link', { name: /Kontakt B/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await expect(page.getByText(/Datenzugang noch nicht eingerichtet/)).toBeVisible();

  console.log('STEP 2b.');
  // 2b. legacy key adoption (typed old private key)
  await page.getByRole('button', { name: 'Altschlüssel übernehmen' }).click();
  const field = page.locator(`#legacy-key-${tenantB}`);
  await field.fill(old.secret.toString('base64url'));
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).nth(1).click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
  await expectReadable(page, 'B Kunde (Umstieg)', 'Kontakt B', markerOld);

  console.log('STEP 2c.');
  // 2c. the access now exists: a passkey unlock after a reload opens the imported customer too
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await expectReadable(page, 'B Kunde (Umstieg)', 'Kontakt B', markerOld);

  console.log('STEP 2d.');
  // 2d. recovery code path: lower case and blanks instead of hyphens (normalisation), then renew the own access
  dropAccess(tenantB);
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await openAdvanced(page);
  await page.locator('#recovery-code').nth(1).fill(oldCode.toLowerCase().replace(/-/g, ' '));
  await page.getByRole('button', { name: 'Öffnen', exact: true }).nth(1).click();
  await expect(page.getByText('Datenschlüssel geöffnet.')).toBeVisible();
  await page
    .getByRole('button', { name: 'Meinen Zugang aus dem Recovery-Code erneuern' })
    .nth(1)
    .click();
  await expect(page.getByText('Ihr Zugang wurde erneuert.')).toBeVisible();
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await expectReadable(page, 'B Kunde (Umstieg)', 'Kontakt B', markerOld);

  console.log('STEP 3.');
  // 3. stale login (older than the fresh window): the recovery code needs a fresh login; the passkey dialog must appear and work
  dropAccess(tenantB);
  sql("UPDATE sessions SET authenticated_at = '2000-01-01 00:00:00.000000'");
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await openAdvanced(page);
  await page.locator('#recovery-code').nth(1).fill(oldCode);
  await page.getByRole('button', { name: 'Öffnen', exact: true }).nth(1).click();
  await page.getByRole('button', { name: 'Mit Passkey bestätigen' }).click();
  await expect(page.getByText('Datenschlüssel geöffnet.')).toBeVisible();

  console.log('STEP 4.');
  // 4. a wrong code names the code, not a generic failure
  dropAccess(tenantB);
  await reloadLocked(page);
  await unlockWithPasskey(page);
  await openAdvanced(page);
  await page.locator('#recovery-code').nth(1).fill('AAAA-BBBB-CCCC-DDDD-EEEE-FFFF-GGGG-HHHH');
  await page.getByRole('button', { name: 'Öffnen', exact: true }).nth(1).click();
  await expect(page.getByText(/Der Wiederherstellungscode passt nicht/)).toBeVisible();

  console.log('STEP 5.');
  // 5. migration stopped half way: generation without recovery wrap. The message says what to do instead (legacy key).
  sql(`DELETE FROM data_key_recovery WHERE customer_id = ${uuidBin(tenantB)}`);
  await page.locator('#recovery-code').nth(1).fill(oldCode);
  await page.getByRole('button', { name: 'Öffnen', exact: true }).nth(1).click();
  await expect(page.getByText(/keine Wiederherstellung hinterlegt/)).toBeVisible();
  await page.locator(`#legacy-key-${tenantB}`).fill(old.secret.toString('base64url'));
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).nth(1).click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();

  console.log('STEP 6.');
  // 6. an older imported generation (retiring) without any access; background automation with a stale login
  const older = legacyKey('QWER-TYUP-ASDF-GHJK-ZXCV-BNM2-3456-789A');
  sql(`
    UPDATE customer_key_generations SET generation_no = 2 WHERE customer_id = ${uuidBin(tenantB)};
    INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
      VALUES (UNHEX(REPLACE(UUID(),'-','')), ${uuidBin(tenantB)}, '${older.kid}', 1, UNHEX('${older.pub.toString('hex')}'), 'retiring', '2024-01-01 10:00:00.000000');
    INSERT INTO data_key_recovery (customer_id, kid, kdf_name, salt, iterations, iv, wrapped_key, created_at)
      VALUES (${uuidBin(tenantB)}, '${older.kid}', 'pbkdf2-hmac-sha256', UNHEX('${older.salt.toString('hex')}'), 600000, UNHEX('${older.iv.toString('hex')}'), UNHEX('${older.wrap.toString('hex')}'), '2024-01-01 10:00:00.000000');
    UPDATE sessions SET authenticated_at = '2000-01-01 00:00:00.000000';
  `);
  resetBudget();
  await reloadLocked(page);
  await unlockWithPasskey(page);
  // The background automation must neither open the passkey dialog on its own nor stay silent. With a stale login it says that a
  // confirmation is needed first (without asking for it); once the login is fresh it names what is missing.
  const dialog = page.getByRole('button', { name: 'Mit Passkey bestätigen' });
  const waitFor = async (hint: Locator) => {
    for (let i = 0; i < 100 && !(await hint.isVisible()); i++) {
      expect(await dialog.isVisible(), 'passkey dialog opened without a user action').toBe(false);
      await page.waitForTimeout(500);
    }
    await expect(hint).toBeVisible();
    expect(await dialog.isVisible()).toBe(false);
  };
  await waitFor(page.getByText(/sobald Sie eine Aktion mit Passkey-Bestätigung ausführen/));
  sql('UPDATE sessions SET authenticated_at = UTC_TIMESTAMP(6)');
  await waitFor(page.getByText(/fehlt Ihr Zugang, daher bleiben deren Einsendungen gesperrt/));
});
