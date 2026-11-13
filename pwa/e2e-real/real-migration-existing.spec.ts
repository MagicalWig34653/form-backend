import { test, expect, type Page } from '@playwright/test';
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
import { expectError, issueCredentials, lost, sizes, snapshot, submit } from './existing-helpers';
import { resetBudget, source, target, uuidBin } from './migration-helpers';

// Umstieg into an EXISTING customer of the target, in the browser, against the REAL backend binary, a real target MariaDB and a real legacy
// MariaDB (synthetic dump). No mocks; orchestrated by backend/e2e-migration-existing.sh.
// The customer owns: a published form (with one SDK submission through the public ingest route), a draft form named like a source form, an
// SMTP connection and its key generation. Everything the customer owned before is fingerprinted (every table with a customer_id column, the
// customer row, its connections and their secrets; all columns, hex, MD5 per row) and must be byte-identical after every run.
// Collisions are caused by real target states and each one is checked on its own: published form in the target, key number, second active
// key, same key id with another public key, form id and connection id already present, customer name differing from the plan.
// Published form and wrong customer name are named errors (target_forms_live, customer_name_mismatch) already in the rehearsal.

const CUSTOMER = 'Bestandskunde AG';
const SAME_NAME = 'Kontaktformular Müller & Söhne 🚀'; // name of source form 1
const SRC_FORM = '11111111-1111-4111-8111-111111111111';
const SRC_SMTP = '44444444-4444-4444-8444-444444444441';
const ownJob = () => target('SELECT state, dry_run, IFNULL(error_code,"-") FROM migration_jobs');
const errorCode = () => target('SELECT IFNULL(error_code,"-") FROM migration_jobs');

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

test('existing customer: own data stays byte-identical, collisions are named, import lands beside it', async ({
  page,
  context,
}) => {
  test.setTimeout(900_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  // ---- the customer's own data, created through the UI and the public ingest route ------------------------------------------------
  const tenant = await createCustomer(page, CUSTOMER);
  const ownForm = await createForm(page, 'Eigenes Formular');
  await configureAndPublish(page, [['email', 'E-Mail', 'email']]);
  const cred = await issueCredentials(page);
  const marker = 'EIGEN-MARKER-' + Math.random().toString(36).slice(2, 8);
  submit(cred, 'own-1', marker);
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  const sameNameForm = await createForm(page, SAME_NAME); // draft, same name as a source form
  // an SMTP connection (no external system is contacted by creating it) assigned to the customer
  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Verbindung anlegen' }).first().click();
  await page.getByLabel('Name', { exact: true }).fill('Eigene SMTP-Verbindung');
  await page.getByLabel('Server', { exact: true }).fill('smtp.eigen.example.invalid');
  await page.getByLabel('Port', { exact: true }).fill('465');
  await page.getByRole('button', { name: 'Verbindung anlegen' }).last().click();
  await expect(
    page.getByRole('paragraph').filter({ hasText: 'Eigene SMTP-Verbindung' }),
  ).toBeVisible();
  await page.getByRole('button', { name: 'Aktionen für Eigene SMTP-Verbindung' }).click();
  await page.getByRole('menuitem', { name: 'Kunden zuweisen' }).click();
  await page.getByRole('checkbox', { name: CUSTOMER }).check();
  await page.getByRole('button', { name: 'Zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();
  const ownConnection = target(
    `SELECT LOWER(HEX(connection_id)) FROM customer_connections WHERE customer_id=${uuidBin(tenant)}`,
  );
  expect(ownConnection).toHaveLength(32);

  expect(
    target(`SELECT COUNT(*) FROM forms WHERE customer_id=${uuidBin(tenant)} AND active=1`),
  ).toBe('1');
  expect(
    target(
      `SELECT COUNT(*) FROM submissions WHERE customer_id=${uuidBin(tenant)} AND state='accepted'`,
    ),
  ).toBe('1');
  expect(
    target(
      `SELECT CONCAT(generation_no,state) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`,
    ),
  ).toBe('1active');
  const published = snapshot(tenant);
  console.log('OWN (published) ' + sizes(published));
  resetBudget();

  // ---- mapping to exactly this customer ----------------------------------------------------------------------------------------------
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Vorhandenen Kunden wählen').selectOption(tenant);
  await expect(page.getByLabel('Kundenname')).toHaveValue(CUSTOMER);
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();

  // ---- collision 1: a form is published in the target ---------------------------------------------------------------------------------
  // perform() refuses every run (rehearsal too) while any form of the target is active or has a release (ADR 0014): its own named error.
  await expectError(
    page,
    /Im Ziel gibt es aktive oder veröffentlichte Formulare.*vor dem Live-Gang/s,
  );
  await expect.poll(errorCode).toBe('target_forms_live');
  expect(lost(published, snapshot(tenant))).toEqual([]);
  expect(sizes(snapshot(tenant))).toBe(sizes(published));
  expect(target('SELECT COUNT(*) FROM migration_objects')).toBe('0');
  expect(target('SELECT COUNT(*) FROM migration_runs')).toBe('0');

  // pausing the form (the only thing the UI offers) does not lift the block: the release stays
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Eigenes Formular/ })
    .first()
    .click();
  await page.getByRole('button', { name: 'Pausieren' }).first().click();
  await page.getByRole('button', { name: 'Pausieren' }).last().click();
  await expect
    .poll(() =>
      target(
        `SELECT active FROM forms WHERE customer_id=${uuidBin(tenant)} AND name='Eigenes Formular'`,
      ),
    )
    .toBe('0');
  expect(
    target(
      `SELECT current_release_id IS NOT NULL FROM forms WHERE customer_id=${uuidBin(tenant)} AND name='Eigenes Formular'`,
    ),
  ).toBe('1');
  const paused = snapshot(tenant);
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /Im Ziel gibt es aktive oder veröffentlichte Formulare/);
  await expect.poll(errorCode).toBe('target_forms_live');
  expect(lost(paused, snapshot(tenant))).toEqual([]);

  // Stand-in for the missing way back (the product has no "unpublish"; the error message says so and points to a fresh target / restore): the form is a draft again, its submission and release rows stay.
  target(`UPDATE forms SET active=0, current_release_id=NULL WHERE id=${uuidBin(ownForm)}`);
  const own = snapshot(tenant);
  console.log('OWN (draft) ' + sizes(own));
  resetBudget();

  // ---- collision 2: the customer's own active key has generation number 1 --------------------------------------------------------------
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /derselben Nummer/);
  await expect.poll(errorCode).toBe('key_conflict_number');
  expect(lost(own, snapshot(tenant))).toEqual([]);
  expect(target('SELECT COUNT(*) FROM migration_objects')).toBe('0');

  // ---- collision 3: free number, but the customer's own key is active (the import would bring a second active one) ---------------------
  target(
    `UPDATE customer_key_generations SET generation_no=9 WHERE customer_id=${uuidBin(tenant)}`,
  );
  const renumbered = snapshot(tenant);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /schon einen aktiven Schlüssel/);
  await expect.poll(errorCode).toBe('key_conflict_active');
  expect(lost(renumbered, snapshot(tenant))).toEqual([]);

  // ---- collision 4: the key id of the source's active key exists in the target with another public key --------------------------------
  const kid = source("SELECT kid FROM datenschluessel WHERE status='aktiv'");
  target(`INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
          VALUES (UNHEX(REPLACE(UUID(),'-','')), ${uuidBin(tenant)}, '${kid}', 7, UNHEX(REPEAT('ab',32)), 'retiring', UTC_TIMESTAMP(6))`);
  const foreignKid = snapshot(tenant);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /Schlüsselkennung ist im Ziel mit einem anderen öffentlichen Schlüssel/);
  await expect.poll(errorCode).toBe('key_conflict_publickey');
  expect(lost(foreignKid, snapshot(tenant))).toEqual([]);
  target(
    `DELETE FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)} AND kid='${kid}'`,
  );

  // ---- collision 5: a form with the id of a source form exists in the target ----------------------------------------------------------
  target(
    `UPDATE customer_key_generations SET state='retiring' WHERE customer_id=${uuidBin(tenant)}`,
  ); // the own key is no longer the active one
  target(
    `INSERT INTO forms (id, customer_id, name, active, created_at) VALUES (${uuidBin(SRC_FORM)}, ${uuidBin(tenant)}, 'Vorhandenes Formular', 0, UTC_TIMESTAMP(6))`,
  );
  const withIdForm = snapshot(tenant);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /Doppelter Eintrag im Ziel/);
  await expect.poll(errorCode).toMatch(/^database@1062/);
  console.log('FORM-ID COLLISION error_code=' + errorCode());
  expect(lost(withIdForm, snapshot(tenant))).toEqual([]);
  expect(target(`SELECT name FROM forms WHERE id=${uuidBin(SRC_FORM)}`)).toBe(
    'Vorhandenes Formular',
  ); // not overwritten
  target(`DELETE FROM forms WHERE id=${uuidBin(SRC_FORM)}`);

  // ---- collision 6: a connection with the id of a source connection exists in the target ------------------------------------------------
  target(
    `INSERT INTO connections (id, kind, name, safe_config_json, credential_ref, enabled) VALUES (${uuidBin(SRC_SMTP)}, 'smtp', 'Vorhandene Verbindung', '{}', NULL, 1)`,
  );
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect.poll(errorCode, { timeout: 120_000 }).toMatch(/^database@1062/);
  await expectError(page, /Doppelter Eintrag im Ziel/);
  console.log('CONNECTION-ID COLLISION error_code=' + errorCode());
  expect(target(`SELECT name FROM connections WHERE id=${uuidBin(SRC_SMTP)}`)).toBe(
    'Vorhandene Verbindung',
  );
  target(`DELETE FROM connections WHERE id=${uuidBin(SRC_SMTP)}`);

  // ---- collision 7: the customer is named differently in the target than in the plan ---------------------------------------------------
  const keyState = snapshot(tenant);
  target(`UPDATE customers SET name='Umbenannter Kunde' WHERE id=${uuidBin(tenant)}`);
  const renamed = snapshot(tenant);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expectError(page, /heißt im Ziel anders als im Plan/);
  await expect.poll(errorCode).toBe('customer_name_mismatch');
  expect(lost(renamed, snapshot(tenant))).toEqual([]);
  expect(target(`SELECT name FROM customers WHERE id=${uuidBin(tenant)}`)).toBe(
    'Umbenannter Kunde',
  ); // never renamed or overwritten
  expect(target('SELECT COUNT(*) FROM migration_objects')).toBe('0');
  expect(target('SELECT COUNT(*) FROM migration_runs')).toBe('0'); // no failed run, nothing written

  // ---- name restored: rehearsal and import now run through, nothing of the customer's own data changed ---------------------------------
  target(`UPDATE customers SET name='${CUSTOMER}' WHERE id=${uuidBin(tenant)}`);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 120_000 });
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect.poll(ownJob, { timeout: 240_000 }).toMatch(/^review\t0/);
  console.log('IMPORT runs: ' + target('SELECT state FROM migration_runs'));
  expect(target("SELECT COUNT(*) FROM migration_objects WHERE source_table='@customers'")).toBe(
    '1',
  );
  expect(target("SELECT COUNT(*) FROM migration_issues WHERE source_table='@customers'")).toBe('0');
  const final = snapshot(tenant);
  console.log('FINAL ' + sizes(final));
  expect(lost(keyState, final)).toEqual([]); // every row the customer owned before the first run: byte-identical
  const counts = () => ({
    forms: target(`SELECT COUNT(*) FROM forms WHERE customer_id=${uuidBin(tenant)}`),
    submissions: target(`SELECT COUNT(*) FROM submissions WHERE customer_id=${uuidBin(tenant)}`),
    objects: target(`SELECT COUNT(*) FROM stored_objects WHERE customer_id=${uuidBin(tenant)}`),
    connections: target(
      `SELECT COUNT(*) FROM customer_connections WHERE customer_id=${uuidBin(tenant)}`,
    ),
    keys: target(
      `SELECT GROUP_CONCAT(CONCAT(generation_no,state) ORDER BY generation_no) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)}`,
    ),
  });
  expect(counts()).toEqual({
    forms: '5', // 2 own + 3 imported
    submissions: '30', // 1 own + 29 imported
    objects: '56',
    connections: '4', // 1 own + 3 imported
    keys: '1retiring,2active,9retiring', // imported 1+2 (2 active), own key renumbered 9 and retiring by the stand-in
  });
  expect(
    target(
      `SELECT COUNT(*) FROM forms WHERE customer_id=${uuidBin(tenant)} AND name='${SAME_NAME}'`,
    ),
  ).toBe('2'); // same name: both exist
  expect(
    target(
      `SELECT COUNT(*) FROM forms WHERE customer_id=${uuidBin(tenant)} AND id IN (${uuidBin(ownForm)}, ${uuidBin(sameNameForm)})`,
    ),
  ).toBe('2');
  expect(
    target(
      `SELECT COUNT(*) FROM submissions WHERE customer_id=${uuidBin(tenant)} AND state='accepted'`,
    ),
  ).toBe('1'); // own, imported ones wait in migration-review
  expect(
    target(
      `SELECT COUNT(*) FROM submissions WHERE customer_id=${uuidBin(tenant)} AND state='migration-review'`,
    ),
  ).toBe('29');

  // ---- coexistence in the UI: the own submission is still listed and readable beside the imported ones ------------------------------------
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Eigenes Formular/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await page
    .getByRole('button', { name: /^Aktionen für Einsendung/ })
    .first()
    .click();
  await page.getByRole('menuitem', { name: 'Öffnen' }).click();
  await expect(page.getByRole('dialog').getByText(marker)).toBeVisible();
});
