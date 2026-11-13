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
  // the browser creates the key after opening the customer: wait for it instead of counting once
  await expect
    .poll(() =>
      target(
        `SELECT COUNT(*) FROM customer_key_generations WHERE customer_id=${uuidBin(tenant)} AND state='active'`,
      ),
    )
    .toBe('1');
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

  // 7. chain to the data: decryption probe -> release of the imported submissions -> list -> old key adopted in the account -> detail
  resetBudget();
  // the page lands on the step "Prüfung" by itself once the repeated import waits for review
  await expect(page.getByRole('heading', { name: 'Prüfung', exact: true }).first()).toBeVisible();
  // 7a. the release button is locked until the decryption probe passed; the server agrees (409), nothing is released
  await expect(
    page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }),
  ).toBeDisabled();
  await expect(page.getByText(/Erst nach bestandener Entschlüsselungsprobe/)).toBeVisible();
  expect(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'")).toBe('0');
  // 7b. probe with the synthetic old key named by the sample (browser-local decryption, human confirmation)
  const probeResponse = page.waitForResponse((r) =>
    /\/migration\/jobs\/[^/]+\/probe$/.test(r.url()),
  );
  await page.getByRole('button', { name: 'Entschlüsselungsprobe laden' }).click();
  const sampleKid = ((await (await probeResponse).json()) as { wire: string }).wire.split('|')[1];
  const probeKey = { a6077815bba8b14c: 0x10, d19bf3f082782c87: 0x11 }[sampleKid];
  expect(probeKey, `sample key id ${sampleKid} is a synthetic old key`).toBeTruthy();
  await page
    .getByLabel('Privater Altschlüssel')
    .fill(Buffer.alloc(32, probeKey).toString('base64url'));
  await page.getByRole('button', { name: 'Probe lokal entschlüsseln' }).click();
  await page.getByRole('alertdialog').getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText(/Lokale Entschlüsselung bestätigt/)).toBeVisible();
  // 7c. release: clean submissions become accepted, the ones with an open review case stay in migration-review
  await expect(
    page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }),
  ).toBeEnabled();
  expect(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'")).toBe('0');
  const effects = () => [
    target('SELECT COUNT(*) FROM mail_deliveries'),
    target('SELECT COUNT(*) FROM webhook_outbox'),
    target('SELECT COUNT(*) FROM stored_objects'),
    target('SELECT MD5(GROUP_CONCAT(HEX(ciphertext_sha256) ORDER BY id)) FROM stored_objects'),
  ];
  const effectsBefore = effects();
  await page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }).click();
  await expect(page.getByTestId('migration-released')).toBeVisible(); // the click is asynchronous: wait for the answer before counting
  const released = Number(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'"));
  const kept = Number(target("SELECT COUNT(*) FROM submissions WHERE state='migration-review'"));
  expect(released).toBeGreaterThan(0);
  expect(kept).toBeGreaterThan(0); // the synthetic dump holds submissions that cannot be taken over (unsupported content)
  expect(released + kept).toBe(Number(first.submissions));
  await expect(page.getByTestId('migration-released')).toHaveText(
    `${released} freigegeben, ${kept} bleiben in der Prüfung.`,
  );
  // no open review case was released, no new effect, packages byte-identical
  expect(
    target(
      "SELECT COUNT(*) FROM submissions s JOIN migration_objects m ON m.source_table='anfragen' AND m.target_table='submissions' AND m.target_key LIKE CONCAT('%',HEX(s.id),'%') JOIN migration_issues i ON i.source_table='anfragen' AND i.source_key=m.source_key AND i.state='open' WHERE s.state='accepted'",
    ),
  ).toBe('0');
  expect(effects()).toEqual(effectsBefore);
  // ledger consistent: the same click again releases nothing more (idempotent)
  await page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }).click();
  await expect(page.getByTestId('migration-released')).toHaveText(
    `${released} freigegeben, ${kept} bleiben in der Prüfung.`,
  );
  expect(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'")).toBe(String(released));
  // 7d. the old key is adopted in the account (browser only), then a released submission opens in clear text
  await page.getByRole('button', { name: 'Zur Übernahme im Konto' }).click();
  await expect(page).toHaveURL(/\/account\?legacy=1/);
  await page.locator(`#legacy-key-${tenant}`).fill(SYNTHETIC_ACTIVE_KEY);
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).first().click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
  expect(
    target(`SELECT COUNT(*) FROM data_key_access WHERE customer_id=${uuidBin(tenant)}`),
  ).not.toBe('0');
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Kontaktformular Müller/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  // the released submissions are listed (before the release this page showed "Noch keine Einsendungen")
  await expect(page.getByText('Noch keine Einsendungen')).toHaveCount(0);
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
