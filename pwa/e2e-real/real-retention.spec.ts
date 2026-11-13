// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
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

// Retention period is mandatory (ADR 0012 no. 2) in a real browser against the real backend + MariaDB (backend/e2e-retention.sh):
// new form = 3 days (72 h) and no "off" option; change to 5, reload shows 5; a real SDK submission carries retention_due_at;
// a form whose setting was removed (SQL) cannot be published: 409 with the reason "Aufbewahrungsfrist fehlt" in the browser.
// E2E_RETENTION_WRONG=1 expects a wrong value after the reload (proof that a failing check ends with rc!=0).

/** One SQL statement against the throwaway database (docker exec into the labelled container of this run). */
function sql(query: string): string {
  return execFileSync(
    env('E2E_DOCKER'),
    [
      'exec',
      '-e',
      `MYSQL_PWD=${env('E2E_DB_PASSWORD')}`,
      env('E2E_DB_CONTAINER'),
      'mariadb',
      '-uroot',
      '-N',
      'e2e',
      '-e',
      query,
    ],
    { encoding: 'utf8' },
  ).trim();
}

test('new form has 3 days, the period is changeable but not removable, publishing needs it', async ({
  page,
  context,
}) => {
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  const tenant = await createCustomer(page, 'Frist Kunde');
  const formA = await createForm(page, 'Frist-Formular');

  // The panel shows the default of a new form: 3 days (72 h); there is no switch to turn the deletion off.
  await page.goto(`/t/${tenant}/f/${formA}/storage`);
  const days = page.getByLabel('Aufbewahrung in Tagen');
  await expect(days).toHaveValue('3');
  await expect(page.getByText(/Standard: 72 Stunden \(3 Tage\)/)).toBeVisible();
  await expect(page.getByLabel('Einsendungen automatisch löschen')).toHaveCount(0);
  await expect(page.getByRole('switch')).toHaveCount(0);
  expect(
    sql(
      `SELECT CAST(safe_value_json AS CHAR) FROM settings WHERE scope_key='form:${formA}' AND setting_key='retention.days'`,
    ),
  ).toBe('3');

  // Change to 5 (typed, not a preset), save, reload: 5.
  await days.fill('5');
  await page.getByRole('button', { name: 'Aufbewahrung speichern' }).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  await page.reload();
  await expect(page.getByLabel('Aufbewahrung in Tagen')).toHaveValue(
    process.env.E2E_RETENTION_WRONG === '1' ? '4' : '5',
  );

  // Publish form A (period present) and make a real submission through the SDK.
  await page.goto(`/t/${tenant}/f/${formA}`);
  await configureAndPublish(page, [['vorname', 'Vorname', 'text']]);
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const credFile = join(mkdtempSync(join(tmpdir(), 'e2e-ret-')), 'credentials.json');
  writeFileSync(credFile, file, { mode: 0o600 });
  const sdk = resolve(process.cwd(), '..', 'sdk', 'php', 'bin', 'submit.php');
  execFileSync(
    'php',
    [
      sdk,
      '--credentials',
      credFile,
      '--url',
      env('E2E_PUBLIC_URL'),
      '--key',
      'e2e-ret-1',
      'nachricht=Frist-Test',
      'vorname=Erika',
    ],
    { encoding: 'utf8' },
  );
  // The submission carries received_at + 5 days.
  expect(
    sql(
      `SELECT DATEDIFF(retention_due_at, received_at) FROM submissions WHERE form_id=UNHEX(REPLACE('${formA}','-',''))`,
    ),
  ).toBe('5');

  // A second form without a stored period (removed by SQL, e.g. older data): publishing is refused with the reason.
  await page.goto(`/t/${tenant}`);
  const formB = await createForm(page, 'Ohne Frist');
  sql(`DELETE FROM settings WHERE scope_key='form:${formB}' AND setting_key='retention.days'`);
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText('Aufbewahrungsfrist fehlt')).toBeVisible();
  expect(sql(`SELECT COUNT(*) FROM releases WHERE form_id=UNHEX(REPLACE('${formB}','-',''))`)).toBe(
    '0',
  );

  // The panel of that form shows the default (3), saving it stores a period,.
  await page.goto(`/t/${tenant}/f/${formB}/storage`);
  await expect(page.getByLabel('Aufbewahrung in Tagen')).toHaveValue('3');
  await page.getByRole('button', { name: '30 Tage' }).click();
  await page.getByRole('button', { name: 'Aufbewahrung speichern' }).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  expect(
    sql(
      `SELECT CAST(safe_value_json AS CHAR) FROM settings WHERE scope_key='form:${formB}' AND setting_key='retention.days'`,
    ),
  ).toBe('30');
});
