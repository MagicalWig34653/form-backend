import { execFileSync } from 'node:child_process';
import { test, expect, type Page } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey, toOverview } from './helpers';
import { resetBudget, source, target } from './migration-helpers';

// Umstieg across process deaths against the REAL service binary (orchestrated by backend/e2e-migration-restart.sh): ONE import is
// interrupted three times in the middle - kill -9, SIGTERM, pause button. After each stop the target must hold whole objects only
// (ledger and target rows agree), the restarted service must leave the job on "paused" (never silently continue), and "Fortsetzen" must
// continue the SAME run. The script compares the end state with an undisturbed import afterwards. No mocks, no sleeps as synchronisation:
// every wait polls the target database.

const ctl = (cmd: string) => execFileSync(env('E2E_APP_CTL'), [cmd], { encoding: 'utf8' });
const total = Number(env('E2E_EXPECTED_TOTAL'));
const jobRow = () =>
  target('SELECT state, phase, dry_run, IFNULL(error_code,"-") FROM migration_jobs');
const state = () => jobRow().split('\t')[0];
const submissions = () => Number(target('SELECT COUNT(*) FROM submissions'));
const ledgerSubmissions = () =>
  Number(
    target(
      "SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='anfragen'",
    ),
  );

async function until(
  what: string,
  read: () => string | number,
  ok: (v: string | number) => boolean,
  timeout = 120_000,
) {
  await expect.poll(() => ok(read()), { message: what, timeout, intervals: [100] }).toBe(true);
}

/** Whole objects only: every ledger entry has its target row, every target row its ledger entry, every package its submission. */
function expectWholeObjects(label: string) {
  console.log(
    `LEDGER ${label}: ${target("SELECT GROUP_CONCAT(CONCAT(target_table,'=',c)) FROM (SELECT target_table, COUNT(*) c FROM migration_objects WHERE source_table='anfragen' GROUP BY target_table) x")} submissions=${target('SELECT COUNT(*) FROM submissions')} objects=${target('SELECT COUNT(*) FROM stored_objects')}`,
  );
  const n = ledgerSubmissions();
  expect(target('SELECT COUNT(*) FROM submissions'), `${label}: submissions vs ledger`).toBe(
    String(n),
  );
  // Each object is written in one transaction together with its ledger entries (importer: START TRANSACTION ... COMMIT per object).
  expect(
    target(
      "SELECT COUNT(*) FROM migration_objects WHERE source_table='anfragen' AND target_table='submissions'",
    ),
    `${label}: ledger entries for submissions vs rows`,
  ).toBe(String(n));
  expect(
    target(
      "SELECT COUNT(*) FROM migration_objects WHERE source_table='anfragen' AND target_table='stored_objects'",
    ),
    `${label}: ledger entries for packages vs rows`,
  ).toBe(target('SELECT COUNT(*) FROM stored_objects WHERE submission_id IS NOT NULL'));
  expect(
    target(
      'SELECT COUNT(*) FROM stored_objects o WHERE o.submission_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM submissions s WHERE s.id = o.submission_id)',
    ),
    `${label}: package without submission`,
  ).toBe('0');
}

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

/** After a stop and a restart: the job stands on paused, then the human resumes it in the UI. */
async function restartAndResume(page: Page, label: string) {
  const before = ledgerSubmissions();
  ctl('start');
  // The recovery runs in the first scheduler tick (2 s cycle): a job left on "running" becomes "paused", never "queued".
  await until(`${label}: job paused after restart`, state, (v) => v === 'paused', 30_000);
  expect(ledgerSubmissions(), `${label}: nothing is imported while paused`).toBe(before);
  await new Promise((r) => setTimeout(r, 5_000)); // two more scheduler ticks: a paused job must stay paused without a human
  expect(state(), `${label}: still paused after further ticks`).toBe('paused');
  expect(ledgerSubmissions()).toBe(before);
  resetBudget();
  await page.reload();
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await until(`${label}: resumed`, state, (v) => v !== 'paused', 30_000);
}

test('migration: import survives kill -9, SIGTERM and the pause button, resumes only by hand', async ({
  page,
  context,
}) => {
  test.setTimeout(420_000);
  const t0 = Date.now();
  const lap = (what: string) => console.log(`T+${Math.round((Date.now() - t0) / 1000)}s ${what}`);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  resetBudget();

  // Setup of the import: source check, a NEW customer, dry run.
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill('Neustart GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  lap('dry run done');
  expect(submissions()).toBe(0);
  expect(source('SELECT COUNT(*) FROM anfragen')).toBe(String(total));

  // The real import starts; each interruption waits for a measured partial state (ledger counter between the thresholds).
  await page.getByRole('button', { name: 'Import starten' }).click();

  // 1. kill -9 in the middle of the submissions
  await until(
    'import running',
    () => ledgerSubmissions(),
    (v) => (v as number) >= total * 0.15,
    240_000,
  );
  ctl('kill9');
  ctl('wait-exit');
  const killed = ledgerSubmissions();
  console.log(`KILL9 at ${killed}/${total} state=${jobRow().replace(/\t/g, ',')}`);
  expect(killed).toBeGreaterThan(0);
  expect(killed).toBeLessThan(total);
  expect(state(), 'a killed process cannot update its job: it still reads running').toBe('running');
  expectWholeObjects('after kill -9');
  await restartAndResume(page, 'kill -9');
  expect(ledgerSubmissions()).toBeGreaterThanOrEqual(killed);

  // 2. SIGTERM (orderly stop) in the middle
  await until(
    'import running again',
    () => ledgerSubmissions(),
    (v) => (v as number) >= total * 0.5,
    240_000,
  );
  ctl('term');
  ctl('wait-exit');
  const termed = ledgerSubmissions();
  console.log(`SIGTERM at ${termed}/${total} state=${jobRow().replace(/\t/g, ',')}`);
  expect(termed).toBeGreaterThan(killed);
  expect(termed).toBeLessThan(total);
  expect(['running', 'paused']).toContain(state()); // orderly: paused at the next object boundary if the database was still reachable
  expectWholeObjects('after SIGTERM');
  await restartAndResume(page, 'SIGTERM');

  // 3. the pause button while the service runs
  await until(
    'import running a third time',
    () => ledgerSubmissions(),
    (v) => (v as number) >= total * 0.75,
    240_000,
  );
  resetBudget();
  await page.getByRole('button', { name: 'Sicher pausieren' }).click();
  await until('paused through the button', state, (v) => v === 'paused', 60_000);
  const pausedAt = ledgerSubmissions();
  console.log(`PAUSE at ${pausedAt}/${total} state=${jobRow().replace(/\t/g, ',')}`);
  expect(pausedAt).toBeLessThan(total);
  expect(jobRow().split('\t')[3]).toBe('interrupted');
  expectWholeObjects('after pause');
  await new Promise((r) => setTimeout(r, 5_000));
  expect(ledgerSubmissions(), 'pause holds without a human').toBe(pausedAt);
  expect(state()).toBe('paused');
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();

  lap('import resumed the last time');
  // The run ends in review; counts source vs target by database queries.
  await until('review', state, (v) => v === 'review', 240_000);
  expect(jobRow()).toBe('review\tverification\t0\t-');
  lap('review reached');
  expectWholeObjects('after the import');
  const counts = () => ({
    forms: target('SELECT COUNT(*) FROM forms'),
    submissions: target('SELECT COUNT(*) FROM submissions'),
    objects: target('SELECT COUNT(*) FROM stored_objects'),
    ledger: target('SELECT COUNT(*) FROM migration_objects'),
    runs: target('SELECT COUNT(*) FROM migration_runs'),
    active: target('SELECT COUNT(*) FROM forms WHERE active=1'),
  });
  const first = counts();
  expect(first.forms).toBe(source('SELECT COUNT(*) FROM formulare'));
  expect(first.submissions).toBe(String(total));
  expect(first.runs).toBe('1'); // all resumes continued the one run
  expect(first.active).toBe('0');
  for (const t of [
    'formulare',
    'formularFelder',
    'anfragen',
    'datenschluessel',
    'datenschluesselRecovery',
    'formularWebhooks',
    'anfrageIdempotenz',
  ])
    expect(
      target(`SELECT COUNT(DISTINCT source_key) FROM migration_objects WHERE source_table='${t}'`),
      `ledger ${t}`,
    ).toBe(source(`SELECT COUNT(*) FROM ${t}`));
  expect(
    target(
      "SELECT COUNT(*) FROM (SELECT target_key FROM migration_objects WHERE target_table='submissions' GROUP BY target_key HAVING COUNT(*)>1) d",
    ),
  ).toBe('0');

  // Repetition with the same snapshot (ADR 0043, no delta): the finished job is put back to "paused" (as after a crash) and resumed;
  // the second import run of the same snapshot changes nothing (no duplicates). The page offers no delta any more.
  resetBudget();
  await expect(page.getByLabel('Neuer Snapshot-SHA256 für Delta-Prüflauf')).toHaveCount(0);
  target("UPDATE migration_jobs SET state='paused'");
  // the page may still show the run step (resume button right there) or already the review step (empty: "Zum Import")
  const toImport = page.getByRole('button', { name: 'Zum Import' });
  const resumeButton = page.getByRole('button', { name: 'Fortsetzen', exact: true });
  await expect(toImport.or(resumeButton)).toBeVisible({ timeout: 30_000 });
  if (await toImport.isVisible()) await toImport.click();
  await resumeButton.click();
  await until(
    'repeated import',
    jobRow,
    (v) => String(v).startsWith('review\tverification\t0'),
    240_000,
  );
  lap('repetition done');
  const again = counts();
  expect(again.runs).toBe('1'); // the same snapshot continues the same run ...
  expect(again).toEqual(first); // ... and changes no data row
});
