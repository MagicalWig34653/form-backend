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
import { expectError, lost, sizes, snapshot } from './existing-helpers';

// Umstieg and the customer key rotation of the target, through the browser against the REAL binary, a real target MariaDB and a real legacy
// MariaDB (synthetic dump). No mocks; orchestrated by backend/e2e-migration-rotation.sh. Expectations are derived from the code:
//  - RotationRoutes.swift POST key-rotation (begin): needs exactly ONE generation of the customer and refuses while any migration_runs row is
//    not 'activated' or any migration_issues row is not 'resolved' (409). Nothing in the product ever sets 'activated' (grep), and an import
//    leaves runs 'failed'/'verified': after an import no customer anywhere can begin a rotation.
//  - The imported customer has TWO generations (old = retiring, newest = active), so the UI offers "Umhängen"/"Abschließen" for it
//    (PUT key-rotation/objects, POST finish): that is the real rotation path available after an import.
//  - LegacyImporter.object(): a ledger entry whose target digest (snapshot of the target row, incl. submissions.state and
//    stored_objects.ciphertext/kid/revision) differs from the stored one throws `conflict` (error code "conflict"); a missing target row
//    throws `missingTarget` ("missing_target"). Datenschluessel is the first table, so a removed generation is reported first.
//  - ADR 0043 (one snapshot, no delta): a repeated run uses the SAME snapshot hash (job set to paused, "Fortsetzen"); a source changed since the
//    dry run stops the real run before writing with `source_changed`, then only "Prüflauf wiederholen" and a new "Import starten" are offered.

const CUSTOMER = 'Rotation GmbH';
const CONTROL = 'Kontrollkunde GmbH';
const KEY_OLD = Buffer.alloc(32, 0x10).toString('base64url'); // kid a6077815bba8b14c (retiring after import)
const KEY_ACTIVE = Buffer.alloc(32, 0x11).toString('base64url'); // kid d19bf3f082782c87 (active after import)
const KID_OLD = 'a6077815bba8b14c';
const KID_ACTIVE = 'd19bf3f082782c87';

async function checkSource(page: Page) {
  // Cause of the former flakes (Todolino E47068F4): Tenants.create navigated to the new customer AFTER the click on "Umstieg"
  // (late navigate() after key preparation). Fixed in the product (no navigation once the list was left); no retry needed here.
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

/** Repeated real run with the SAME snapshot (ADR 0043): the job is put back to paused like after a crash and resumed in the browser. */
async function repeatRun(page: Page) {
  resetBudget();
  target("UPDATE migration_jobs SET state='paused'");
  await goTo(page, 'Umstieg');
  const resume = page.getByRole('button', { name: 'Fortsetzen', exact: true });
  const toRun = page.getByRole('button', { name: 'Zum Import' });
  await expect(resume.or(toRun).first()).toBeVisible({ timeout: 30_000 }); // the page reloads the jobs and lands on the step of the job
  if (!(await resume.isVisible())) await toRun.click();
  await resume.click();
}

const job = () => target('SELECT dry_run, state, IFNULL(error_code,"-") FROM migration_jobs');

/** Row count + content hash of the ledger and of the whole target apart from run bookkeeping. */
const ledger = () =>
  target(
    "SELECT COUNT(*), MD5(GROUP_CONCAT(CONCAT(source_table,'|',HEX(source_key),'|',target_slot,'|',HEX(source_hmac),'|',HEX(target_hmac)) ORDER BY source_table,source_key,target_slot)) FROM migration_objects",
  );

async function goTo(page: Page, link: string) {
  await page.getByRole('link', { name: link, exact: true }).first().click();
}

async function openAccountAdvanced(page: Page) {
  await goTo(page, 'Mein Konto');
  const summary = page.locator('#account-advanced');
  await expect(summary).toBeVisible();
  if ((await page.locator('details[open] #account-advanced').count()) === 0) await summary.click();
}

async function adopt(page: Page, tenant: string, key: string) {
  const field = page.locator(`#legacy-key-${tenant}`);
  await field.fill(key);
  await field
    .locator('xpath=ancestor::form')
    .getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' })
    .click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
}

/** Opens the entry list of the first imported form of the customer and returns the field rows of the OLDEST listed entry. */
async function readOldestEntry(page: Page): Promise<Record<string, string>> {
  await goTo(page, 'Kunden');
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Kontaktformular Müller/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  const buttons = page.getByRole('button', { name: /^Aktionen für Einsendung/ });
  await expect(buttons.first()).toBeVisible();
  await buttons.last().click();
  await page.getByRole('menuitem', { name: 'Öffnen' }).click();
  const detail = page.getByRole('dialog', { name: 'Einsendungsdetail' });
  await expect(detail.getByRole('heading', { name: 'Felder' })).toBeVisible();
  await expect(detail.getByText(/konnte nicht|passt nicht|Schlüssel/)).toHaveCount(0);
  const labels = await detail.locator('dt').allInnerTexts();
  const values = await detail.locator('dt + dd').allInnerTexts();
  await page.keyboard.press('Escape');
  return Object.fromEntries(labels.map((l, i) => [l.trim(), values[i]]));
}

test('migration x rotation: real rotation of the imported key, repeated import, readability', async ({
  page,
  context,
}) => {
  test.setTimeout(900_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  const tenant = await createCustomer(page, CUSTOMER);
  await toOverview(page);
  await page.waitForTimeout(1500);
  const control = await createCustomer(page, CONTROL); // a customer with one active generation, untouched by the import
  const own = (id: string) => uuidBin(id);
  resetBudget();

  // 1. import into the existing customer (same chain as real-migration.spec.ts)
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await page.getByLabel('Vorhandenen Kunden wählen').selectOption(tenant);
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByRole('alert').filter({ hasText: 'derselben Nummer' })).toBeVisible({
    timeout: 120_000,
  });
  target(`
    DELETE FROM data_key_access WHERE customer_id = ${own(tenant)};
    DELETE FROM data_key_recovery WHERE customer_id = ${own(tenant)};
    DELETE FROM customer_key_generations WHERE customer_id = ${own(tenant)};
  `);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 120_000 });
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(job()).toBe('0\treview\t-');
  const gens = (id: string) =>
    target(
      `SELECT GROUP_CONCAT(CONCAT(generation_no,state,':',kid) ORDER BY generation_no) FROM customer_key_generations WHERE customer_id=${own(id)}`,
    );
  expect(gens(tenant)).toBe(`1retiring:${KID_OLD},2active:${KID_ACTIVE}`);
  const submissions0 = Number(target('SELECT COUNT(*) FROM submissions'));
  expect(submissions0).toBe(Number(source('SELECT COUNT(*) FROM anfragen')));
  const runStates = target('SELECT GROUP_CONCAT(DISTINCT state) FROM migration_runs');
  console.log(
    'RUN-STATES after import',
    runStates,
    'open issues',
    target("SELECT COUNT(*) FROM migration_issues WHERE state<>'resolved'"),
  );

  // 2. state before any browser access to the old keys. Marker n of the first form was written under the old key iff n <= 4
  // (RehearsalSource: first half of perForm=8 under alphaOld). NOTE: the browser's access automation (automation.svelte.ts) rewraps and
  // finishes a retiring generation BY ITSELF as soon as the keyring holds access to both generations; the old keys are therefore adopted
  // only after the repeated runs of step 4, so that those run against the freshly imported key state.
  const kidOfMarker = (m: number) =>
    target(
      `SELECT GROUP_CONCAT(DISTINCT o.kid) FROM stored_objects o JOIN submissions s ON s.id=o.submission_id WHERE o.object_role='data' AND s.received_at=FROM_UNIXTIME(${1_700_000_000 + m * 3600}) AND s.customer_id=${own(tenant)}`,
    );
  expect(kidOfMarker(1)).toBe(KID_OLD);
  expect(target(`SELECT COUNT(*) FROM data_key_access WHERE customer_id=${own(tenant)}`)).toBe('0');
  const payloads = () =>
    target(
      `SELECT MD5(GROUP_CONCAT(HEX(payload_sha256) ORDER BY id)) FROM stored_objects WHERE customer_id=${own(tenant)}`,
    );
  target("UPDATE submissions SET state='accepted' WHERE state='migration-review'"); // SQL stand-in (E050F35C open: unchanged), see step 4

  // 4. repeated real run (same snapshot) with the SQL-accepted state: the ledger digest of submissions.state differs -> `conflict`, nothing written
  // Cause of the former flake (audit_events 6 instead of 5): the browser's key automation (automation.svelte.ts, 30-s timer) fetches the
  // recovery wrap of a generation it cannot open (ensureGeneration -> repairAutomatic -> GET key-recovery) and the server audits every such
  // read as `key.recovery.read` (KeyManagementRoutes.swift, intended). That read happens when the timer fires, independent of the import job,
  // so the customer's audit rows may grow by exactly this action. Everything else stays compared exactly: any other new audit row, any
  // changed row and any row count of another table still fails the test.
  const BACKGROUND_AUDIT = ['key.recovery.read'];
  const snap = (id: string) => snapshot(id, { ignoreAudit: BACKGROUND_AUDIT });
  const fpTenant = snap(tenant);
  const fpControl = snapshot(control);
  const ledger0 = ledger();
  await repeatRun(page);
  await expect.poll(job, { timeout: 120_000 }).toBe('0\tfailed\tconflict');
  await expectError(page, /abweichende Daten/);
  expect(lost(fpTenant, snapshot(tenant))).toEqual([]);
  expect(sizes(snap(tenant))).toBe(sizes(fpTenant));
  expect(ledger()).toBe(ledger0);
  // state back to what the importer wrote; the source gets two NEW submissions (one per generation) before the same job is resumed:
  // the source fingerprint of the dry run no longer matches -> `source_changed` before any write, then a new dry run and a new import
  target("UPDATE submissions SET state='migration-review' WHERE state='accepted'");
  const fpImported = snapshot(tenant); // the state the importer wrote
  const clone = (kid: string, seconds: number) =>
    source(`INSERT INTO anfragen (UUID,time,formularUUID,sentServer,data,malwareScanStatus,removable)
      SELECT UUID(), ${seconds}, formularUUID, sentServer, data, 'kein_upload', 1 FROM anfragen
      WHERE data LIKE 'KUBUS-AEAD:2|${kid}|hpke|%' AND mailBody IS NULL AND file1Enc IS NULL AND file1Name IS NULL AND file1 IS NULL
        AND formularUUID=(SELECT formularUUID FROM anfragen ORDER BY ID LIMIT 1) LIMIT 1`);
  clone(KID_OLD, 1_770_000_000);
  clone(KID_ACTIVE, 1_770_000_100);
  expect(source('SELECT COUNT(*) FROM anfragen')).toBe(String(submissions0 + 2));
  const fpConflict = snapshot(tenant);
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect.poll(job, { timeout: 120_000 }).toBe('0\tfailed\tsource_changed');
  await expectError(page, /Altdaten wurden seit dem Prüflauf verändert/);
  await expect(page.getByRole('button', { name: 'Fortsetzen', exact: true })).toHaveCount(0); // only a new dry run helps
  expect(Number(target('SELECT COUNT(*) FROM submissions'))).toBe(submissions0);
  expect(lost(fpConflict, snapshot(tenant))).toEqual([]);
  expect(ledger()).toBe(ledger0);
  resetBudget();
  await page.getByRole('button', { name: 'Prüflauf wiederholen' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  expect(job()).toBe('1\treview\t-');
  expect(Number(target('SELECT COUNT(*) FROM submissions'))).toBe(submissions0); // a dry run adds nothing
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect
    .poll(() => (job().includes('failed') ? 'failed' : job()), { timeout: 240_000 })
    .toMatch(/review|failed/);
  console.log('IMPORT-AFTER-REHEARSAL', job(), 'phase', target('SELECT phase FROM migration_jobs'));
  expect(job()).toBe('0\treview\t-');
  // the new submissions: written next to the old ones, each under the generation named in its own package, still migration-review
  expect(Number(target('SELECT COUNT(*) FROM submissions'))).toBe(submissions0 + 2);
  const newKids = target(
    `SELECT GROUP_CONCAT(DISTINCT o.kid ORDER BY o.kid) FROM stored_objects o JOIN submissions s ON s.id=o.submission_id WHERE s.received_at >= '2026-01-01' AND s.customer_id=${own(tenant)}`,
  );
  console.log('NEW-SUBMISSIONS generations', newKids);
  expect(newKids).toBe(`${KID_OLD},${KID_ACTIVE}`);
  expect(
    target(
      "SELECT GROUP_CONCAT(DISTINCT state) FROM submissions WHERE received_at >= '2026-01-01'",
    ),
  ).toBe('migration-review');
  expect(lost(fpImported, snapshot(tenant))).toEqual([]); // every earlier row of the customer is byte-identical
  expect(lost(fpControl, snapshot(control))).toEqual([]);

  // 5. rotation as the product offers it. a customer with ONE generation cannot begin: the open migration blocks every customer
  resetBudget();
  await openAccountAdvanced(page);
  const beginButtons = page.getByRole('button', { name: 'Rotation beginnen' });
  await expect(beginButtons).toHaveCount(1); // only the control customer; the imported one already has a retiring generation
  const beginResponse = page.waitForResponse(
    (r) => /\/key-rotation$/.test(r.url()) && r.request().method() === 'POST',
  );
  await beginButtons.click();
  const begin = await beginResponse;
  const beginBody = await begin.text();
  console.log('BEGIN-ROTATION control customer', begin.status(), beginBody);
  expect(begin.status()).toBe(409);
  // the cause ("Migration ist nicht abgeschlossen", RotationRoutes.swift) is NOT in the answer: the error handler reduces every 409 to "Konflikt."
  expect(JSON.parse(beginBody).code).toBe('conflict');
  expect(beginBody).not.toContain('Migration');
  await expect(page.getByText(/Rotation fehlgeschlagen/)).toBeVisible();
  expect(gens(control)).toMatch(/^1active:/); // nothing changed
  expect(lost(fpControl, snapshot(control))).toEqual([]);

  // 6. the REAL rotation of the imported key: adopting both old keys in the browser starts the product's own automation (rewrap of every object
  // of the retiring generation in the browser, then finish), no button involved. Nothing in it may change the payloads.
  const objectsOld = Number(
    target(
      `SELECT COUNT(*) FROM stored_objects WHERE customer_id=${own(tenant)} AND kid='${KID_OLD}'`,
    ),
  ); // includes the object of the submission the second import added under the old key
  expect(objectsOld).toBeGreaterThan(0);
  const fpPre = snapshot(tenant);
  const payloadsPre = payloads();
  resetBudget();
  await openAccountAdvanced(page);
  await adopt(page, tenant, KEY_ACTIVE);
  await adopt(page, tenant, KEY_OLD);
  await expect
    .poll(() => gens(tenant), { timeout: 150_000, intervals: [2000] })
    .toBe(`2active:${KID_ACTIVE}`);
  expect(
    target(
      `SELECT COUNT(*) FROM stored_objects WHERE customer_id=${own(tenant)} AND kid='${KID_OLD}'`,
    ),
  ).toBe('0');
  expect(payloads()).toBe(payloadsPre); // only key envelopes changed, never the payload
  expect(
    target(
      `SELECT COUNT(*) FROM audit_events WHERE action_code='key.rotation.rewrap' AND customer_id=${own(tenant)}`,
    ),
  ).toBe(String(objectsOld));
  expect(
    target(
      `SELECT COUNT(*) FROM audit_events WHERE action_code='key.rotation.finish' AND customer_id=${own(tenant)}`,
    ),
  ).toBe('1');
  for (const table of ['data_key_access', 'data_key_recovery'])
    expect(
      target(`SELECT COUNT(*) FROM ${table} WHERE customer_id=${own(tenant)} AND kid='${KID_OLD}'`),
    ).toBe('0');
  expect(lost(fpPre, snapshot(tenant)).length).toBeGreaterThan(0); // stored_objects/generations changed, as intended
  const fpFinished = snap(tenant);
  const ledger2 = ledger();
  expect(lost(fpControl, snapshot(control))).toEqual([]);

  // 7. repeated import (same snapshot, source unchanged since the second dry run) against the rotated target: the ledger entry of the removed
  //    generation has no target any more -> `missing_target` (datenschluessel is the first table; the rewrapped stored_objects would be
  //    `conflict` next, never reached). Nothing is written.
  await repeatRun(page);
  await expect.poll(job, { timeout: 120_000 }).toBe('0\tfailed\tmissing_target');
  await expectError(page, /Ziel der Zuordnung existiert nicht/);
  console.log('REPEAT-AFTER-ROTATION', job(), 'phase', target('SELECT phase FROM migration_jobs'));
  expect(lost(fpFinished, snapshot(tenant))).toEqual([]);
  expect(sizes(snap(tenant))).toBe(sizes(fpFinished));
  expect(ledger()).toBe(ledger2);
  expect(Number(target('SELECT COUNT(*) FROM submissions'))).toBe(submissions0 + 2);
  // the same job resumed (repeated run): same named answer, still nothing written
  resetBudget();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect.poll(job, { timeout: 120_000 }).toBe('0\tfailed\tmissing_target');
  expect(ledger()).toBe(ledger2);
  expect(lost(fpFinished, snapshot(tenant))).toEqual([]);

  // 8. the OLD submissions stay readable after the rotation: the oldest entry (marker 1, written under the removed generation, now rewrapped
  //    under the active one) opens in the browser with the adopted key and shows the plaintext known from the synthetic dump
  target("UPDATE submissions SET state='accepted' WHERE state='migration-review'");
  const after = await readOldestEntry(page);
  console.log('ENTRY-AFTER', JSON.stringify(after));
  expect(after['Marker']).toBe('KLARTEXT-MARKER-1');
  expect(after['Name']).toBe('Jörg Müßig 1');
  expect(after['Email']).toBe('joerg1@example.invalid');
  expect(after['Nachricht']).toBe('Grüße 👋🏽 — Ärger mit Öl & Äpfeln\n\tZeile 2 "zitiert" \\ Pfad');
  expect(kidOfMarker(1)).toBe(KID_ACTIVE);
  target("UPDATE submissions SET state='migration-review' WHERE state='accepted'");

  // 9. causality of the refusal in step 5: with the SQL stand-in (all runs 'activated', all issues 'resolved'; the product has no such transition)
  // the very same click begins a rotation. Both customers hold ONE generation now, so exactly one of them is rotated by the first button.
  target(
    "UPDATE migration_runs SET state='activated'; UPDATE migration_issues SET state='resolved'",
  );
  resetBudget();
  await openAccountAdvanced(page);
  await expect(page.getByRole('button', { name: 'Rotation beginnen' })).toHaveCount(2);
  const ok = page.waitForResponse(
    (r) => /\/key-rotation$/.test(r.url()) && r.request().method() === 'POST',
  );
  await page.getByRole('button', { name: 'Rotation beginnen' }).first().click();
  expect((await ok).status()).toBe(201);
  expect(target("SELECT COUNT(*) FROM audit_events WHERE action_code='key.rotation.begin'")).toBe(
    '1',
  );
  expect(
    target(
      'SELECT COUNT(*) FROM (SELECT customer_id FROM customer_key_generations GROUP BY customer_id HAVING COUNT(*)=2) x',
    ),
  ).toBe('1');
});
