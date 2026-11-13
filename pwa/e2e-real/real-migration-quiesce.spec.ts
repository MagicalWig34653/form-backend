import { test, expect, type Page } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey, toOverview } from './helpers';
import { resetBudget, source, target } from './migration-helpers';

// Umstieg: one snapshot, quiesce checked in code (ADR 0043) through the browser against the REAL backend binary, a real target MariaDB and
// a real legacy MariaDB (synthetic dump). No mocks; orchestrated by backend/e2e-migration-quiesce.sh.
// Chain: source check -> mapping -> dry run (the job report carries the source fingerprint) -> the legacy system is written (a submission is
// DELETED by SQL after the rehearsal) -> "Import starten" -> the reason `source_changed` is shown, NOTHING is written to the target
// (no run, no object, no customer) -> "Prüflauf wiederholen" -> import -> the deleted submission is missing in the target (database check).
// E2E_QUIESCE_WRONG=1 turns the final expectation around (the deleted submission "must" be in the target): the run has to fail (rc=1).

const CUSTOMER = 'Quiesce GmbH';
const wrong = process.env.E2E_QUIESCE_WRONG === '1';

async function checkSource(page: Page) {
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
}

test('migration quiesce: legacy data deleted after the rehearsal -> source_changed, nothing written, rehearse again, import', async ({
  page,
  context,
}) => {
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  resetBudget();

  // 1. source check, mapping to a new customer, dry run
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill(CUSTOMER);
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  const job = () => target('SELECT dry_run, state FROM migration_jobs');
  expect(job()).toBe('1\treview');
  const rehearsalFingerprint = target(
    "SELECT JSON_UNQUOTE(JSON_EXTRACT(report_json,'$.sourceFingerprint')) FROM migration_jobs",
  );
  expect(rehearsalFingerprint).toMatch(/^[0-9a-f]{64}$/);
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0'); // a dry run leaves nothing behind

  // 2. the legacy system is written after the rehearsal: one submission is deleted (as an operator who forgot the write pause would do)
  const deletedID = source('SELECT ID FROM anfragen ORDER BY ID DESC LIMIT 1');
  expect(deletedID).toMatch(/^[0-9]+$/);
  const before = Number(source('SELECT COUNT(*) FROM anfragen'));
  source(`SET FOREIGN_KEY_CHECKS=0; DELETE FROM anfragen WHERE ID=${deletedID}`);
  expect(Number(source('SELECT COUNT(*) FROM anfragen'))).toBe(before - 1);

  // 3. import: refused with the reason, nothing written in the target
  resetBudget();
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(
    page.getByRole('alert').filter({ hasText: 'Die Altdaten wurden seit dem Prüflauf verändert' }),
  ).toBeVisible({ timeout: 180_000 });
  expect(target('SELECT dry_run, state, error_code FROM migration_jobs')).toBe(
    '0\tfailed\tsource_changed',
  );
  for (const table of [
    'migration_runs',
    'migration_objects',
    'customers',
    'forms',
    'submissions',
    'stored_objects',
    'customer_key_generations',
  ])
    expect(target(`SELECT COUNT(*) FROM ${table}`), `${table} after source_changed`).toBe('0');
  // the plain "Fortsetzen" would fail again: the page offers the new rehearsal instead
  await expect(page.getByRole('button', { name: 'Fortsetzen', exact: true })).toHaveCount(0);

  // 4. rehearse again: same plan, new fingerprint, still no write
  await page.getByRole('button', { name: 'Prüflauf wiederholen' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  expect(job()).toBe('1\treview');
  const newFingerprint = target(
    "SELECT JSON_UNQUOTE(JSON_EXTRACT(report_json,'$.sourceFingerprint')) FROM migration_jobs",
  );
  expect(newFingerprint).toMatch(/^[0-9a-f]{64}$/);
  expect(newFingerprint).not.toBe(rehearsalFingerprint);
  expect(target('SELECT COUNT(*) FROM migration_runs')).toBe('0');

  // 5. import with the quiet legacy system: the deleted submission is missing in the target (database check, not the page)
  resetBudget();
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(job()).toBe('0\treview');
  expect(target('SELECT COUNT(*) FROM migration_runs')).toBe('1');
  expect(target('SELECT COUNT(*) FROM submissions')).toBe(String(before - 1));
  const inLedger = target(
    `SELECT COUNT(*) FROM migration_objects WHERE source_table='anfragen' AND source_key=CAST('${deletedID}' AS BINARY)`,
  );
  // wrong expectation on purpose (E2E_QUIESCE_WRONG=1): the deleted submission "is" in the target -> this expectation has to fail
  expect(inLedger, 'ledger entry of the deleted legacy submission').toBe(wrong ? '1' : '0');
  expect(
    target(
      'SELECT JSON_UNQUOTE(JSON_EXTRACT(report_json,"$.sourceFingerprint")) FROM migration_jobs',
    ),
  ).toBe(newFingerprint); // the import ran on exactly the state the second rehearsal saw
});
