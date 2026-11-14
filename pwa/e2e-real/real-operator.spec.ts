import { test, expect, type Page } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey } from './helpers';
import { note, resetBudget, source, stepDone, target } from './real-operator-helpers';
import { CUSTOMER, postImport } from './real-operator-production';

// Operator path with the PUBLISHED image (backend/e2e-operator.sh): empty instance -> setup -> Umstieg exactly as docs/UMSTIEG-CHECKLISTE.md
// describes it (new customer by name, TLS "verify" against the source) -> import -> review -> cutover -> production use.
// E2E_DUMP=real: an operator's real dump (values never printed): everything except what needs the old private key (not in the dump).

async function sourceCheck(page: Page) {
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
  await page.getByLabel('Host', { exact: true }).fill(env('E2E_SRC_HOST'));
  await page.getByLabel('Port', { exact: true }).fill(env('E2E_SRC_PORT'));
  await page.getByLabel('Datenbank', { exact: true }).fill(env('E2E_LEGACY_DB'));
  await page.getByLabel('Benutzer', { exact: true }).fill(env('E2E_LEGACY_USER'));
  await page.getByLabel('Passwort', { exact: true }).fill(env('E2E_LEGACY_PASSWORD'));
  await expect(page.getByLabel('TLS-Modus')).toHaveValue('verify'); // the default an operator keeps
  await page.getByRole('button', { name: /^(Verbindung prüfen|Erneut prüfen)$/ }).click();
  const ok = page.getByText(/Nur lesender Zugang geprüft/);
  const err = page.getByRole('alert').first();
  await expect(ok.or(err)).toBeVisible({ timeout: 120_000 });
  if (!(await ok.isVisible()))
    throw new Error(`source check: ${(await err.innerText()).split('\n')[0]}`);
  await expect(page.getByText('Prüfbericht der Quelle')).toBeVisible();
}

test('operator path: setup, Umstieg, production use', async ({ page, context }) => {
  page.on('console', (m) => {
    if (m.type() === 'error') console.log('CONSOLE', m.text().slice(0, 200));
  });
  page.on('response', async (r) => {
    if (r.status() < 400) return;
    // Error bodies are the fixed public problem envelope (code, requestId): no submission data.
    const problem = await r.text().then(
      (t) => t.slice(0, 160),
      () => '',
    );
    console.log(
      `HTTP ${r.status()} ${r.request().method()} ${new URL(r.url()).pathname} ${problem}`,
    );
  });
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));

  // 1. setup: enrollment link -> passkey -> recovery code
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  const recovery = await loginAndSecure(page);
  expect(recovery).toMatch(/^[A-Z0-9]{4}(-[A-Z0-9]{4}){7}$/);
  stepDone('setup-passkey-recovery');

  // 2. source check over TLS (verify), read-only account with special characters, database name with a hyphen
  resetBudget();
  await sourceCheck(page);
  stepDone('source-check');

  // 3. mapping: the documented way is the customer NAME (UMSTIEG-CHECKLISTE 2.2); nothing else is touched
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').first().fill(CUSTOMER);
  const summary = page.getByTestId('migration-summary');
  await expect(summary).toBeVisible();
  note(`mapping summary: ${(await summary.innerText()).replace(/\s+/g, ' ').slice(0, 300)}`);
  stepDone('mapping');

  // 4. dry run
  resetBudget();
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  const dryOk = page.getByText('Der Prüflauf ist abgeschlossen.');
  const dryFail = page.getByText(/Prüflauf: Fehlgeschlagen/);
  await expect(dryOk.or(dryFail)).toBeVisible({ timeout: 600_000 });
  if (await dryFail.isVisible()) {
    note(`dry run failed: ${target('SELECT state, error_code FROM migration_jobs')}`);
    throw new Error('dry run failed');
  }
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0');
  stepDone('dry-run');

  // 5. import
  resetBudget();
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 900_000,
  });
  note(`job: ${target('SELECT dry_run, state, COALESCE(error_code,"-") FROM migration_jobs')}`);
  stepDone('import');

  // 6. counts source vs target (by queries) and the open review cases by code
  const counts = {
    forms: [source('SELECT COUNT(*) FROM formulare'), target('SELECT COUNT(*) FROM forms')],
    submissions: [
      source('SELECT COUNT(*) FROM anfragen'),
      target('SELECT COUNT(*) FROM submissions'),
    ],
    connections: [
      source(
        'SELECT (SELECT COUNT(*) FROM outgoingMailServer)+(SELECT COUNT(*) FROM outgoingMailProxy)',
      ),
      target('SELECT COUNT(*) FROM connections'),
    ],
    keys: [
      source('SELECT COUNT(*) FROM datenschluessel'),
      target('SELECT COUNT(*) FROM customer_key_generations'),
    ],
  };
  note(`counts source/target: ${JSON.stringify(counts)}`);
  note(
    `review cases: ${target("SELECT GROUP_CONCAT(CONCAT(source_table,':',issue_code,'=',n)) FROM (SELECT source_table, issue_code, COUNT(*) n FROM migration_issues GROUP BY 1,2) x")}`,
  );
  note(`customers: ${target('SELECT GROUP_CONCAT(state) FROM customers')}`);
  for (const [k, [s, t]] of Object.entries(counts)) expect(t, k).toBe(s);
  stepDone('counts');

  await postImport(page, recovery);
});
