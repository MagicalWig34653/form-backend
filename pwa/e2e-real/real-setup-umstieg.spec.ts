import { test, expect, type Page } from '@playwright/test';
import {
  addAuthenticator,
  configureAndPublish,
  env,
  loginAndSecure,
  registerPasskey,
} from './helpers';
import { resetBudget, source, target } from './migration-helpers';
import { reloadLocked } from './unlock-helpers';

// Setup assistant (/installation) with the Umstieg in one go against the REAL binary, real target and legacy MariaDB (synthetic dump),
// no mocks; orchestrated by backend/e2e-setup-umstieg.sh. Conflict/resume/count/key-adoption details are covered by real-migration.spec.ts.
// Chain: empty database -> passkey -> recovery code -> assistant (steps, progress) -> step "Umstieg" -> source check, mapping, dry run,
// import -> back in the assistant: the Umstieg step is recognised as done
// and the progress counter matches the step states on the page.

const STEPS = [
  'account',
  'recovery',
  'passkeys',
  'addresses',
  'mail',
  'customer',
  'form',
  'token',
  'testEntry',
  'migration',
];

async function states(page: Page): Promise<Record<string, string>> {
  const out: Record<string, string> = {};
  for (const id of STEPS)
    out[id] = (await page.getByTestId(`step-${id}`).getAttribute('data-state')) ?? 'missing';
  return out;
}

/** The progress text on the page must equal the number of steps in state done (and the total the number of steps). */
async function expectProgressMatches(page: Page): Promise<number> {
  const s = await states(page);
  const done = Object.values(s).filter((v) => v === 'done').length;
  await expect(page.getByTestId('setup-progress')).toContainText(
    `${done} von ${STEPS.length} Schritten erledigt`,
  );
  return done;
}

test('setup assistant: Umstieg in one go, step is recognised as done afterwards', async ({
  page,
  context,
}) => {
  test.setTimeout(300_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page); // ends on the assistant ("Einrichtung")

  // 1. the assistant shows all steps and its progress is derived from the data
  await expect(page.getByLabel('Einrichtungsschritte').getByRole('listitem')).toHaveCount(
    STEPS.length,
  );
  const before = await states(page);
  console.log('STATES before', JSON.stringify(before));
  expect(before.account).toBe('done');
  expect(before.recovery).toBe('done');
  expect(before.passkeys).toBe('open'); // one passkey only, two wanted
  expect(before.customer).toBe('open');
  expect(before.form).toBe('open');
  expect(before.migration).toBe('open');
  const doneBefore = await expectProgressMatches(page);
  expect(target('SELECT COUNT(*) FROM customers')).toBe('0');
  expect(target('SELECT COUNT(*) FROM migration_jobs')).toBe('0');
  resetBudget();

  // 2. the step leads into the Umstieg; the setup bar leads back
  await page.getByTestId('step-migration').getByRole('button', { name: 'Umstieg öffnen' }).click();
  await expect(page).toHaveURL(/\/migration/);
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
  await expect(page.getByTestId('setup-bar')).toContainText('Schritt 10 von 10');

  // 3. source check, mapping to a NEW customer, dry run, import
  await page.getByLabel('Host', { exact: true }).fill('127.0.0.1');
  await page.getByLabel('Port', { exact: true }).fill(env('E2E_LEGACY_PORT'));
  await page.getByLabel('Datenbank', { exact: true }).fill(env('E2E_LEGACY_DB'));
  await page.getByLabel('Benutzer', { exact: true }).fill(env('E2E_LEGACY_USER'));
  await page.getByLabel('Passwort', { exact: true }).fill(env('E2E_LEGACY_PASSWORD'));
  await page.getByLabel('TLS-Modus').selectOption('disable');
  await page.getByRole('button', { name: 'Verbindung prüfen' }).click();
  await expect(page.getByText(/Nur lesender Zugang geprüft/)).toBeVisible();
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill('Umstieg Setup GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0');

  // 3a. a finished dry run is NOT the import: back in the assistant the Umstieg step stays open and names the state
  await page
    .getByTestId('setup-bar')
    .getByRole('button', { name: 'Zurück zur Einrichtung' })
    .first()
    .click();
  await expect(page).toHaveURL(/\/installation/);
  const mig = page.getByTestId('step-migration');
  await expect(mig).toHaveAttribute('data-state', 'open');
  await expect(page.getByTestId('migration-run-hint')).toContainText('Prüflauf ist erledigt');
  await expect(page.getByTestId('customer-imported-hint')).toHaveCount(0); // nothing imported yet
  expect(await expectProgressMatches(page)).toBe(doneBefore);
  await mig.getByRole('button', { name: 'Umstieg öffnen' }).click();
  await expect(page.getByRole('button', { name: 'Import starten' })).toBeVisible({
    timeout: 60_000,
  });
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(target('SELECT dry_run, state FROM migration_jobs ORDER BY created_at DESC LIMIT 1')).toBe(
    '0\treview',
  );
  expect(target('SELECT COUNT(*) FROM submissions')).toBe(source('SELECT COUNT(*) FROM anfragen'));
  expect(target('SELECT COUNT(*) FROM forms')).toBe(source('SELECT COUNT(*) FROM formulare'));
  expect(target("SELECT COUNT(*) FROM customers WHERE name='Umstieg Setup GmbH'")).toBe('1');

  // 4. back in the assistant (setup bar): the Umstieg step is recognised as done, the progress is consistent
  await page
    .getByTestId('setup-bar')
    .getByRole('button', { name: 'Zurück zur Einrichtung' })
    .first()
    .click();
  await expect(page).toHaveURL(/\/installation/);
  await expect(page.getByTestId('step-migration')).toHaveAttribute('data-state', 'done');
  // The facts of the steps load independently (tenants, jobs, ...): wait for the customer step instead of reading it in the same instant.
  await expect(page.getByTestId('step-customer')).toHaveAttribute('data-state', 'done');
  const after = await states(page);
  console.log('STATES after', JSON.stringify(after));
  // The importer creates customers ACTIVE (finding A of the operator path, 13.11.2026): the imported customer is listed under /tenants
  // and the customer step is done; its forms stay inactive and unpublished until the cutover.
  expect(target("SELECT state FROM customers WHERE name='Umstieg Setup GmbH'")).toBe('active');
  expect(after.customer).toBe('done');
  expect(after.form).toBe('open'); // imported forms are inactive/unpublished: not "published"
  expect(after.passkeys).toBe('open');
  const doneAfter = await expectProgressMatches(page);
  expect(doneAfter).toBe(doneBefore + 2); // migration and customer (the imported customer is active)
  await expect(page.getByTestId('step-migration')).toContainText('Der Import ist durchgeführt');
  await expect(page.getByTestId('migration-run-hint')).toHaveCount(0);
  await expect(
    page.getByTestId('step-migration').getByRole('link', { name: 'Importläufe ansehen' }),
  ).toBeVisible();
  // the assistant is not finishable yet (steps open), the finish button stays disabled
  await expect(page.getByRole('button', { name: 'Einrichtung abschließen' })).toBeDisabled();

  // 6. further steps that need no external system, offered by the assistant itself: first active customer, first published form
  const mailStep = page.getByTestId('step-mail');
  await expect(mailStep).toHaveAttribute('data-state', 'open'); // no mail connection exists (an SMTP server is an external system)
  await expect(mailStep.getByRole('button', { name: 'Verbindung anlegen' })).toBeVisible();
  // 6a. after a reload the keyring is locked (RAM only): creating the customer (its key is made in the browser) names the unlock path,
  // not "set up and save the recovery code". The customer row itself is created and counted; its key follows once unlocked.
  await reloadLocked(page);
  await expect(page.getByTestId('step-migration')).toHaveAttribute('data-state', 'done');
  // the imported (active) customer already completes the customer step; the locked key shows up when the form is created below
  await expect(page.getByTestId('step-customer')).toHaveAttribute('data-state', 'done');
  await expect(page.getByTestId('customer-imported-hint')).toHaveCount(0);
  await expect(page.getByTestId('step-form')).toHaveAttribute('data-state', 'open');
  await page.getByLabel('Name des Formulars').fill('Assistent Formular');
  await page.getByRole('button', { name: 'Formular anlegen', exact: true }).click();
  // The imported customer already has its key on the server (imported generation), so creating the form needs no new customer key and
  // works with the locked keyring (probed 13.11.): the form page opens; the setup bar leads back.
  await expect(page).toHaveURL(/\/f\/[0-9a-f-]{36}/);
  expect(target("SELECT COUNT(*) FROM forms WHERE name='Assistent Formular'")).toBe('1');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  await page
    .getByTestId('setup-bar')
    .getByRole('button', { name: 'Zurück zur Einrichtung' })
    .first()
    .click();
  await expect(page.getByTestId('step-form')).toHaveAttribute('data-state', 'done');
  expect(await expectProgressMatches(page)).toBe(doneAfter + 1); // form (the customer was already done)
  await expect(page.getByTestId('step-testEntry')).toHaveAttribute('data-state', 'open');
  await expect(page.getByTestId('step-migration')).toHaveAttribute('data-state', 'done'); // the Umstieg step is unaffected

  // 7. a reload recomputes the same state from the server (nothing is held in the browser; the keyring is locked again, which changes no step)
  await page.reload();
  await expect(page.getByTestId('step-migration')).toHaveAttribute('data-state', 'done');
  expect(await expectProgressMatches(page)).toBe(doneAfter + 1);
});
