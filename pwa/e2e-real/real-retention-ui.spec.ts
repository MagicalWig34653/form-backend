// SPDX-License-Identifier: AGPL-3.0-only
import { execFileSync } from 'node:child_process';
import { test, expect, type Page, type Request } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey, toOverview } from './helpers';

// Retention panel with IMPORTED submissions in a real browser against the real backend, a real target MariaDB and a legacy import
// (backend/e2e-retention-ui.sh; QA D945BDCD, card C174F624). The retention job runs every 2 s.
// Form A (3 -> 5 -> 2 days): save without the checkbox, cancel in each dialog (no request), then the confirmed apply (two dialogs, because the
//   period is shortened AND imported rows are included).
// Form B (3 days unchanged, only the checkbox): one dialog, exactly one PUT with applyToImported=true.
// E2E_RETENTION_UI_WRONG=1 expects one wrong number (red proof, exit != 0).

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
const bin = (uuid: string) => `UNHEX('${uuid.replace(/-/g, '')}')`;
const num = (query: string) => Number(sql(query));

interface Put {
  days?: number;
  applyToImported?: boolean;
  dryRun?: boolean;
}
/** Records every PUT .../retention the page sends. */
function recordPuts(page: Page): { real: () => Put[]; dry: () => Put[] } {
  const all: Put[] = [];
  page.on('request', (r: Request) => {
    if (r.method() === 'PUT' && /\/forms\/[0-9a-f-]{36}\/retention$/.test(r.url()))
      all.push(JSON.parse(r.postData() ?? '{}') as Put);
  });
  return { real: () => all.filter((p) => !p.dryRun), dry: () => all.filter((p) => p.dryRun) };
}

const imported = (form: string) =>
  `customer_id IS NOT NULL AND form_id=${bin(form)} AND release_evidence='legacy-unknown'`;
const dueAt = (form: string, days: number) =>
  num(
    `SELECT COUNT(*) FROM submissions WHERE ${imported(form)} AND removable=1 AND received_at IS NOT NULL AND DATE_ADD(received_at, INTERVAL ${days} DAY) <= UTC_TIMESTAMP()`,
  );
const total = (form: string) => num(`SELECT COUNT(*) FROM submissions WHERE ${imported(form)}`);
/** Rows the server may date: those without received_at never get a due date (the apply statement skips them). */
const withoutDue = (form: string) =>
  num(
    `SELECT COUNT(*) FROM submissions WHERE ${imported(form)} AND retention_due_at IS NULL AND received_at IS NOT NULL`,
  );
const period = (form: string) =>
  num(
    `SELECT CAST(safe_value_json AS CHAR) FROM settings WHERE scope_key='form:${form}' AND setting_key='retention.days'`,
  );

async function openPanel(page: Page, tenant: string, form: string) {
  await page.goto(`/t/${tenant}/f/${form}/storage`);
  await expect(page.getByTestId('retention-imported')).toBeVisible();
}
const save = (page: Page) => page.getByRole('button', { name: 'Aufbewahrung speichern' });
const dialog = (page: Page) => page.getByRole('alertdialog');

test('imported submissions: dry run, save without the box, cancel, confirmed apply, job deletes only the due ones', async ({
  page,
  context,
}) => {
  test.setTimeout(180_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  // two forms with removable imported submissions (the fixture decides which)
  const rows = sql(
    `SELECT LOWER(INSERT(INSERT(INSERT(INSERT(HEX(form_id),9,0,'-'),14,0,'-'),19,0,'-'),24,0,'-')), LOWER(INSERT(INSERT(INSERT(INSERT(HEX(customer_id),9,0,'-'),14,0,'-'),19,0,'-'),24,0,'-')) FROM submissions WHERE release_evidence='legacy-unknown' AND removable=1 GROUP BY form_id, customer_id ORDER BY COUNT(*) DESC`,
  )
    .split('\n')
    .map((l) => l.split('\t'));
  expect(
    rows.length,
    'at least two imported forms with removable submissions',
  ).toBeGreaterThanOrEqual(2);
  const [formA, tenant] = rows[0];
  const [formB, tenantB] = rows[1];
  console.log('INFO forms', formA, formB, 'imported', total(formA), total(formB));

  const puts = recordPuts(page);
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);

  const datedB = withoutDue(formB);
  // ---- Form A ----
  await openPanel(page, tenant, formA);
  const totalA = total(formA);
  const datedA = withoutDue(formA);
  expect(withoutDue(formA)).toBe(datedA);
  const days = page.getByLabel('Aufbewahrung in Tagen');
  await expect(days).toHaveValue('3');

  // dry run: the shown number is the number the database would make due at the typed period
  await days.fill('5');
  const due5 = dueAt(formA, 5);
  await expect(page.getByTestId('retention-imported-due')).toContainText(
    `Bei 5 Tagen wären ${due5} importierte Einsendungen sofort fällig`,
  );
  expect(puts.dry().some((p) => p.days === 5)).toBe(true);
  expect(puts.real()).toHaveLength(0);

  // save WITHOUT the box: one PUT without applyToImported, imported rows keep NULL, the job (2 s) deletes nothing
  await save(page).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  expect(puts.real()).toEqual([{ days: 5 }]);
  expect(period(formA)).toBe(5);
  expect(withoutDue(formA)).toBe(datedA);
  await page.waitForTimeout(6_000);
  expect(total(formA)).toBe(totalA);

  // cancel: shorten to 2 days with the box. First dialog "Speichern und löschen" -> Abbrechen: nothing is sent.
  await days.fill('2');
  await page.getByLabel('Frist auch auf die importierten Einsendungen anwenden').check();
  const due2 = dueAt(formA, 2);
  await expect(page.getByTestId('retention-imported-due')).toContainText(
    `Bei 2 Tagen wären ${due2} importierte Einsendungen sofort fällig`,
  );
  await save(page).click();
  await expect(dialog(page)).toContainText('Aufbewahrung verkürzen');
  await dialog(page).getByRole('button', { name: 'Abbrechen' }).click();
  await expect(dialog(page)).toHaveCount(0);
  await page.waitForTimeout(500);
  expect(puts.real()).toHaveLength(1);
  // second dialog "Anwenden und löschen" -> Abbrechen: still nothing is sent
  await save(page).click();
  await dialog(page).getByRole('button', { name: 'Speichern und löschen' }).click();
  await expect(dialog(page)).toContainText('Importierte Einsendungen einbeziehen');
  await expect(dialog(page)).toContainText(`${due2} importierte Einsendungen`);
  await dialog(page).getByRole('button', { name: 'Abbrechen' }).click();
  await expect(dialog(page)).toHaveCount(0);
  await page.waitForTimeout(500);
  expect(puts.real()).toHaveLength(1);
  expect(period(formA)).toBe(5);
  expect(withoutDue(formA)).toBe(datedA);

  // confirmed: both dialogs, exactly one more PUT with applyToImported=true
  await save(page).click();
  await dialog(page).getByRole('button', { name: 'Speichern und löschen' }).click();
  await expect(dialog(page)).toContainText('Importierte Einsendungen einbeziehen');
  await dialog(page).getByRole('button', { name: 'Anwenden und löschen' }).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  expect(puts.real()).toEqual([{ days: 5 }, { days: 2, applyToImported: true }]);
  expect(period(formA)).toBe(2);
  expect(withoutDue(formA)).toBe(0);
  // the job removes exactly the due (and not held) ones
  await expect.poll(() => total(formA), { timeout: 30_000 }).toBe(totalA - due2);
  await page.waitForTimeout(5_000);
  expect(total(formA)).toBe(totalA - due2);
  // the other form was not touched
  expect(withoutDue(formB)).toBe(datedB);

  // ---- Form B: period stays 3, only the box (the case of the QA finding) ----
  const totalB = total(formB);
  const due3 = dueAt(formB, 3);
  await openPanel(page, tenantB, formB);
  await expect(page.getByLabel('Aufbewahrung in Tagen')).toHaveValue('3');
  const before = puts.real().length;
  await page.getByLabel('Frist auch auf die importierten Einsendungen anwenden').check();
  await save(page).click();
  // no shortening: ONE dialog with the label "Anwenden und löschen" (there is no "Speichern und löschen" here)
  await expect(dialog(page)).toContainText('Importierte Einsendungen einbeziehen');
  await expect(dialog(page).getByRole('button', { name: 'Speichern und löschen' })).toHaveCount(0);
  await dialog(page).getByRole('button', { name: 'Anwenden und löschen' }).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  expect(puts.real().slice(before)).toEqual([{ days: 3, applyToImported: true }]);
  expect(withoutDue(formB)).toBe(0);
  await expect
    .poll(() => total(formB), { timeout: 30_000 })
    .toBe(totalB - due3 + (process.env.E2E_RETENTION_UI_WRONG === '1' ? 1 : 0));
});
