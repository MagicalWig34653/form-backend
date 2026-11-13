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
import { resetBudget, source, target, uuidBin } from './migration-helpers';

// Umstieg step 4 ("Entwürfe und Konverterbericht erstellen") through the browser against the REAL backend binary, a real target MariaDB
// and a real legacy MariaDB loaded from the synthetic dump. No mocks; orchestrated by backend/e2e-migration-convert.sh.
// Chain: import up to state `review` -> convert in the UI -> one draft per old form, field count and kinds per source (DB + UI) ->
// second conversion adds nothing -> open a draft in the editor, change the title, save -> publish -> conversion of the released form
// is refused with 409 "bereits freigegeben".
// Chain 6 (imported run -> old key adopted in the browser -> imported submission readable) is covered by real-migration.spec.ts.
// E2E_EXPECT_DRAFT_FIELDS overrides the expected total of draft fields (a deliberately wrong value must fail the run).

const CUSTOMER = 'Konverter GmbH';
// Old kinds of the synthetic dump -> editor kinds; 'datei' is not mappable (converter: "Dateifelder benötigen Anhangprüfung").
const KIND_MAP: Record<string, string | null> = { text: 'text', email: 'email', datei: null };

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

const draftRows = () =>
  target(
    `SELECT HEX(form_id), JSON_LENGTH(JSON_EXTRACT(document_json,'$.form.fields')), revision FROM form_drafts ORDER BY form_id`,
  );
const titleOf = (formId: string) =>
  target(
    `SELECT JSON_UNQUOTE(JSON_EXTRACT(document_json,'$.form.title.de')) FROM form_drafts WHERE form_id=${uuidBin(formId)}`,
  );

test('migration convert: drafts from the import, repetition, edit, publish, 409 for a released form', async ({
  page,
  context,
}) => {
  test.skip(process.env.E2E_REAL_DUMP === '1', 'needs the synthetic source');
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  let csrf = '';
  page.on('request', (r) => {
    const t = r.headers()['x-csrf-token'];
    if (t) csrf = t;
  });
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  // The import goes into an existing (active) customer here (a new imported customer is active as well since 13.11.2026, see
  // real-operator.spec.ts). Its own key generation (number 1) would collide with the imported one, so it is removed first (as in real-migration.spec.ts).
  const tenant = await createCustomer(page, CUSTOMER);
  // The browser sets up the customer's key generation, its access and (later) its recovery asynchronously after the customer is created:
  // wait until the access exists, then dismantle all three in ONE transaction (a delete in between would hit data_key_access' foreign key).
  await expect
    .poll(
      () => target(`SELECT COUNT(*) FROM data_key_access WHERE customer_id = ${uuidBin(tenant)}`),
      { timeout: 30_000 },
    )
    .not.toBe('0');
  target(`
    START TRANSACTION;
    DELETE FROM data_key_access WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM data_key_recovery WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM customer_key_generations WHERE customer_id = ${uuidBin(tenant)};
    COMMIT;
  `);
  resetBudget();

  // 1. import up to review
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await page.getByLabel('Vorhandenen Kunden wählen').selectOption(tenant);
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(target('SELECT dry_run, state FROM migration_jobs')).toBe('0\treview');
  expect(target('SELECT COUNT(*) FROM forms')).toBe(source('SELECT COUNT(*) FROM formulare'));
  // FINDING (annotation): the import run itself converts every form (MigrationService phase `conversion`, LegacyConversionRoutes.perform),
  // so the drafts exist before anybody presses the button; the button only repeats the (idempotent) conversion and fetches the report.
  expect(target('SELECT COUNT(*) FROM form_drafts')).toBe('3');
  test.info().annotations.push({
    type: 'finding',
    description:
      'import run already created one draft per form (phase conversion); the UI button "Entwürfe und Konverterbericht erstellen" is a repeat',
  });
  resetBudget();

  // 2. to prove that the button itself creates drafts: take one draft away (DB), press the button, it comes back
  const victim = target('SELECT HEX(form_id) FROM migration_form_drafts ORDER BY form_id LIMIT 1');
  target(`SET FOREIGN_KEY_CHECKS=0;
    DELETE FROM migration_form_drafts WHERE form_id=UNHEX('${victim}');
    DELETE FROM form_drafts WHERE form_id=UNHEX('${victim}');`);
  expect(target('SELECT COUNT(*) FROM form_drafts')).toBe('2');
  const convertName = 'Entwürfe und Konverterbericht erstellen';
  await page.getByRole('button', { name: convertName }).click();
  await expect(page.getByText(/Inaktive Entwurfsvorschläge erstellt/)).toBeVisible();

  // 3. database: one draft per old form, field count and kinds per source
  const nForms = source('SELECT COUNT(*) FROM formulare');
  expect(nForms).toBe('3');
  expect(target('SELECT COUNT(*) FROM form_drafts')).toBe(nForms);
  expect(target('SELECT COUNT(DISTINCT form_id) FROM form_drafts')).toBe(nForms);
  expect(target('SELECT COUNT(*) FROM migration_form_drafts')).toBe(nForms);
  expect(target('SELECT COUNT(*) FROM forms WHERE active=1')).toBe('0');
  expect(target('SELECT COUNT(*) FROM releases')).toBe('0');
  const srcFields = source('SELECT formularUUID, typ FROM formularFelder ORDER BY ID')
    .split('\n')
    .map((l) => l.split('\t'));
  expect(srcFields.length).toBe(7);
  const mappable = srcFields.filter(([, typ]) => KIND_MAP[typ] !== null).length;
  const expected = process.env.E2E_EXPECT_DRAFT_FIELDS ?? String(mappable);
  expect(
    target(`SELECT SUM(JSON_LENGTH(JSON_EXTRACT(document_json,'$.form.fields'))) FROM form_drafts`),
  ).toBe(expected);
  for (const uuid of new Set(srcFields.map(([h]) => h))) {
    const want = srcFields
      .filter(([h]) => h === uuid)
      .map(([, typ]) => KIND_MAP[typ])
      .filter((k): k is string => k !== null)
      .sort()
      .join(',');
    const got = target(
      `SELECT GROUP_CONCAT(j.kind) FROM form_drafts d, JSON_TABLE(JSON_EXTRACT(d.document_json,'$.form.fields.*.kind'), '$[*]' COLUMNS (kind VARCHAR(32) PATH '$')) j
        WHERE d.form_id = UNHEX(REPLACE('${uuid}','-',''))`,
    )
      .split(',')
      .filter(Boolean)
      .sort()
      .join(',');
    expect(got, `kinds of ${uuid}`).toBe(want);
  }
  // the unmappable file field is named in the converter report, not silently dropped
  expect(
    target(`SELECT COUNT(*) FROM migration_form_drafts WHERE report_json LIKE '%nicht abbildbar%'`),
  ).not.toBe('0');
  const before = draftRows();

  // 4. second conversion: no duplicate, no revision change
  await page.reload();
  resetBudget();
  await page.getByRole('button', { name: convertName }).click();
  await expect(page.getByText(/Inaktive Entwurfsvorschläge erstellt/)).toBeVisible();
  expect(target('SELECT COUNT(*) FROM form_drafts')).toBe(nForms);
  expect(draftRows()).toBe(before);

  // 5. open the imported form "Kontaktformular Müller" in the editor, change the title, save
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Kontaktformular Müller/ })
    .first()
    .click();
  const formId = /\/f\/([0-9a-f-]{36})/.exec(page.url())![1];
  await page.getByRole('link', { name: 'Felder', exact: true }).click();
  await expect(page.getByText('nachricht', { exact: true }).first()).toBeVisible(); // label = old field name
  await expect(page.getByText('anhang', { exact: true })).toHaveCount(0); // the file field was not converted
  await page.getByLabel('Titel des Formulars').fill('Kontaktformular Müller (geprüft)');
  await page.getByRole('button', { name: 'Titel speichern' }).click();
  await expect.poll(() => titleOf(formId)).toBe('Kontaktformular Müller (geprüft)');
  expect(
    Number(target(`SELECT revision FROM form_drafts WHERE form_id=${uuidBin(formId)}`)),
  ).toBeGreaterThan(1);

  // 6. publish the converted draft (no external service involved)
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  const published = page.waitForResponse(
    (r) => r.url().endsWith('/releases') && r.request().method() === 'POST',
  );
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  const status = (await published).status();
  const released = () =>
    target(
      `SELECT COUNT(*) FROM forms WHERE id=${uuidBin(formId)} AND current_release_id IS NOT NULL`,
    );
  // The import owns form_versions(version_no=1, 'migration-review'); the first release must take the next number (was HTTP 500).
  expect(status).toBe(201);
  expect(released()).toBe('1');
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
  expect(
    target(
      `SELECT GROUP_CONCAT(version_no ORDER BY version_no) FROM form_versions WHERE form_id=${uuidBin(formId)}`,
    ),
  ).toBe('1,2');
  expect(
    target(
      `SELECT contract_version FROM form_versions WHERE form_id=${uuidBin(formId)} AND version_no=1`,
    ),
  ).toBe('migration-review'); // the imported version stays untouched
  expect(target('SELECT COUNT(*) FROM form_drafts')).toBe(nForms);

  // 7. conversion of a released form is refused with 409 "bereits freigegeben": the UI button only converts the imported forms, so a
  // natively created and published form of the same customer is addressed by the route itself, from the signed-in browser session
  // (CSRF token taken from the SPA's own requests).
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  const nativeId = await createForm(page, 'Natives Formular');
  await configureAndPublish(page, [['mail', 'E-Mail', 'email']]);
  expect(
    target(
      `SELECT COUNT(*) FROM forms WHERE id=${uuidBin(nativeId)} AND current_release_id IS NOT NULL AND active=1`,
    ),
  ).toBe('1');
  resetBudget();
  expect(csrf).not.toBe('');
  const refused = await page.request.post(
    `/admin/api/v1/migration/legacy-forms/${nativeId}/draft`,
    { headers: { 'X-CSRF-Token': csrf, Origin: new URL(page.url()).origin } },
  );
  const detail = await refused.text();
  expect(refused.status(), detail).toBe(409);
  // The reason "Formular ist bereits freigegeben" (LegacyConversionRoutes.swift:44) never reaches the client: the error handler answers
  // with the generic body below, so the Umstieg page can only say "Konflikt".
  expect(JSON.parse(detail)).toMatchObject({ code: 'conflict', message: 'Konflikt.' });
  test.info().annotations.push({
    type: 'finding',
    description:
      '409 for a released form carries only the generic message "Konflikt." (reason "bereits freigegeben" is swallowed)',
  });
  expect(target('SELECT COUNT(*) FROM form_drafts WHERE form_id=' + uuidBin(nativeId))).toBe('1'); // only its own draft
  expect(target('SELECT COUNT(*) FROM migration_form_drafts')).toBe(nForms);
});
