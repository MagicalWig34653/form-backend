import { test, expect, type Page } from '@playwright/test';
import {
  addAuthenticator,
  createCustomer,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';
import { resetBudget, source, target, uuidBin } from './migration-helpers';

// Umstieg through the browser against the REAL backend binary, a real target MariaDB and a real legacy MariaDB loaded from the
// synthetic dump (backend/Tests/FormMigrationTests/Fixtures/legacy-synthetic.sql). No mocks; orchestrated by backend/e2e-migration.sh.
// Chain: source check -> mapping to an existing customer that already has an active key (real conflict) -> German message -> remove the
// cause in the target -> resume the SAME job -> dry run -> real import -> counts source vs target -> repeated run changes nothing ->
// adopt the old key in the account (recovery code of the synthetic envelope) -> a submission is readable in clear text.
// With E2E_REAL_DUMP=1 (an operator's own dump instead of the synthetic one) only the source check and the dry run are exercised.

const CUSTOMER = 'Altkunde GmbH';
const SYNTHETIC_ACTIVE_KEY = 'ERERERERERERERERERERERERERERERERERERERERERE'; // seed 0x11 of RehearsalSource (base64url)

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
  await expect(page.getByText('Prüfbericht der Quelle')).toBeVisible();
}

test('migration: source check, real conflict, resume, import, repetition, key adoption, readable submission', async ({
  page,
  context,
}) => {
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  const realDump = process.env.E2E_REAL_DUMP === '1';

  // The target customer exists already and has its own active key generation (created in the browser with the passkey).
  const tenant = await createCustomer(page, CUSTOMER);
  expect(
    target(
      `SELECT COUNT(*) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)} AND state='active'`,
    ),
  ).toBe('1');
  resetBudget();

  // 1. source check and mapping
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Vorhandenen Kunden wählen').selectOption(tenant);
  await expect(page.getByLabel('Kundenname')).toHaveValue(CUSTOMER);
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();

  if (realDump) {
    await expect(page.getByText(/Prüflauf: (Wartet auf Prüfung|Fehlgeschlagen)/)).toBeVisible({
      timeout: 120_000,
    });
    return;
  }

  // 2. the real conflict: the customer's own key already uses generation number 1 (the dry run changes nothing)
  const alert = page.getByRole('alert').filter({ hasText: 'derselben Nummer' });
  await expect(alert).toBeVisible({ timeout: 120_000 });
  expect(target('SELECT COUNT(*) FROM forms')).toBe('0');
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0');
  expect(
    target(`SELECT COUNT(*) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`),
  ).toBe('1');

  // 3. cause removed in the target (the message names this way: dismantle the key), the SAME job is resumed
  target(`
    DELETE FROM data_key_access WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM data_key_recovery WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM customer_key_generations WHERE customer_id = ${uuidBin(tenant)};
  `);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 120_000 });
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0'); // a dry run leaves nothing behind

  // 4. real import
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  await expect(page.getByTestId('migration-report')).toContainText('Einsendungen');

  // 5. counts source vs target by database queries (not by the page): every object of the old store is in the target and the ledger
  const counts = () => ({
    forms: target('SELECT COUNT(*) FROM forms'),
    submissions: target('SELECT COUNT(*) FROM submissions'),
    generations: target('SELECT COUNT(*) FROM customer_key_generations'),
    recovery: target('SELECT COUNT(*) FROM data_key_recovery'),
    objects: target('SELECT COUNT(*) FROM stored_objects'),
    ledger: target('SELECT COUNT(*) FROM migration_objects'),
    active: target('SELECT COUNT(*) FROM forms WHERE active=1'),
  });
  const ledgerOf = (table: string) =>
    target(
      `SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='${table}'`,
    );
  const first = counts();
  expect(first.forms).toBe(source('SELECT COUNT(*) FROM formulare'));
  expect(first.submissions).toBe(source('SELECT COUNT(*) FROM anfragen'));
  expect(first.generations).toBe(source('SELECT COUNT(*) FROM datenschluessel'));
  expect(first.recovery).toBe(source('SELECT COUNT(*) FROM datenschluesselRecovery'));
  expect(first.active).toBe('0'); // everything stays inactive until the human cutover
  for (const t of [
    'formulare',
    'formularFelder',
    'anfragen',
    'datenschluessel',
    'datenschluesselRecovery',
    'outgoingMailServer',
    'outgoingMailProxy',
    'formularWebhooks',
    'anfrageIdempotenz',
  ])
    expect(ledgerOf(t), `ledger ${t}`).toBe(source(`SELECT COUNT(*) FROM ${t}`));
  expect(
    target(
      `SELECT GROUP_CONCAT(CONCAT(generation_no,state) ORDER BY generation_no) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`,
    ),
  ).toBe('1retiring,2active');
  expect(target(`SELECT COUNT(*) FROM forms WHERE customer_id=${uuidBin(tenant)}`)).toBe('3');

  // 6. repetition with the SAME snapshot (ADR 0043: no delta, no new snapshot hash). The page offers no delta any more; an interrupted run
  // (the job is put back to "paused" like after a crash) is resumed in the browser, and the repeated import changes and duplicates nothing
  await expect(page.getByLabel('Neuer Snapshot-SHA256 für Delta-Prüflauf')).toHaveCount(0);
  const job = () => target('SELECT dry_run, state FROM migration_jobs');
  expect(job()).toBe('0\treview');
  expect(
    target(
      "SELECT JSON_UNQUOTE(JSON_EXTRACT(report_json,'$.sourceFingerprint')) FROM migration_jobs",
    ),
  ).toMatch(/^[0-9a-f]{64}$/); // the job report carries the source fingerprint (a hash, never a value)
  target("UPDATE migration_jobs SET state='paused'");
  await page.getByRole('button', { name: 'Zum Import' }).click();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect.poll(job, { timeout: 240_000 }).toBe('0\treview'); // the repeated import ran through
  expect(counts()).toEqual(first);
  expect(target('SELECT COUNT(*) FROM migration_runs')).toBe('1'); // same snapshot: the same run, no second one

  // 7. chain to the data: the old key is adopted in the account (browser only), then a submission opens in clear text
  resetBudget();
  await page.getByRole('button', { name: 'Weiter' }).click(); // review step
  await page.getByRole('button', { name: 'Zur Übernahme im Konto' }).click();
  await expect(page).toHaveURL(/\/account\?legacy=1/);
  await page.locator(`#legacy-key-${tenant}`).fill(SYNTHETIC_ACTIVE_KEY);
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).first().click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
  expect(
    target(`SELECT COUNT(*) FROM data_key_access WHERE customer_id=${uuidBin(tenant)}`),
  ).not.toBe('0');
  // OPEN PRODUCT FINDING (reported, not hidden): the importer writes every submission as state 'migration-review' (Transform.swift) and no
  // code ever turns it into 'accepted'; the entries routes only serve 'accepted'. Without the next statement the list stays empty
  // ("Noch keine Einsendungen") although key adoption worked. The statement stands in for the missing product decision (who accepts
  // imported submissions, and when) so that the rest of the chain, decryption in the browser with the adopted key, is still proven.
  expect(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'")).toBe('0');
  test.info().annotations.push({
    type: 'finding',
    description:
      'imported submissions stay in state migration-review and are not listed or readable (no transition to accepted)',
  });
  target("UPDATE submissions SET state='accepted' WHERE state='migration-review'");
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Kontaktformular Müller/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await page
    .getByRole('button', { name: /^Aktionen für Einsendung/ })
    .first()
    .click();
  await page.getByRole('menuitem', { name: 'Öffnen' }).click();
  // The package opens in the browser with the adopted key (the newest entry of the form is a legacy "sym" package). "Felder" is only
  // rendered after a successful local decryption and JSON parse; a wrong or missing key shows an error notice instead.
  const detail = page.getByRole('dialog', { name: 'Einsendungsdetail' });
  await expect(detail.getByRole('heading', { name: 'Felder' })).toBeVisible();
  await expect(detail.getByText(/konnte nicht|passt nicht|Schlüssel/)).toHaveCount(0);
  // The legacy payload is a flat JSON object (field name -> value, docs/handoffs/Alt-Payload-Format.md). Names AND values known from the
  // synthetic dump (RehearsalSource.plain) must be shown; the labels are the old field names made readable.
  const marker = (await detail.getByText(/KLARTEXT-MARKER-\d+/).innerText()).trim();
  const n = marker.replace('KLARTEXT-MARKER-', '');
  const row = (label: string, value: string | RegExp) =>
    expect(
      detail
        .locator('dt', { hasText: new RegExp(`^${label}$`) })
        .locator('xpath=following-sibling::dd[1]'),
    ).toHaveText(value);
  await row('Name', `Jörg Müßig ${n}`);
  await row('Email', `joerg${n}@example.invalid`);
  await row('Nachricht', 'Grüße 👋🏽 — Ärger mit Öl & Äpfeln\n\tZeile 2 "zitiert" \\ Pfad');
  await row('Form', /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  await row('Marker', marker);
  await expect(detail.locator('dt', { hasText: /^Leer$/ })).toHaveCount(1); // an empty value is still a field
});
