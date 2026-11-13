import { writeFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { test, expect, type Page } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey } from './helpers';
import { resetBudget, target } from './migration-helpers';

// Source check over REAL TLS through the browser (orchestrated by backend/e2e-migration-tls.sh): real backend, real target MariaDB, a real
// legacy MariaDB with a certificate from a throw-away CA, a second one without TLS. No mocks. Each scenario asserts what the user sees AND what
// the source server itself recorded (TLS handshake counters, general log), never only the page.

// A certificate problem names its cause: host name, unknown CA (SourceFailure.certUntrusted), expired (found by a credential-free diagnosis connection
// that only sends the SSLRequest). The TLS source's general log (table) proves that no login of the account ever reached it in the failure cases.
const HOSTNAME = 'passt nicht zum Hostnamen';
const UNTRUSTED = 'unbekannten Stelle';
const EXPIRED = 'ist abgelaufen';
const EXPECT_WRONG = process.env.E2E_TLS_EXPECT_WRONG === '1'; // red-green proof only: an intentionally wrong expectation

const sql = (container: string, password: string, statement: string) =>
  execFileSync(
    'docker',
    [
      'exec',
      '-i',
      '-e',
      `MYSQL_PWD=${password}`,
      container,
      'mariadb',
      '--skip-ssl',
      '-uroot',
      '-N',
    ],
    { input: statement, encoding: 'utf8' },
  ).trim();
const tlsSrc = (s: string) => sql(env('E2E_LEGACY_CONTAINER'), env('E2E_LEGACY_ROOT_PASSWORD'), s);
const plainSrc = (s: string) => sql(env('E2E_PLAIN_CONTAINER'), env('E2E_PLAIN_ROOT_PASSWORD'), s);

/** Swaps the certificate the TLS source serves (same key, different certificate) and reloads it without restarting the server. */
function serve(cert: 'good' | 'wronghost' | 'unknownca' | 'expired') {
  const dir = env('E2E_CERT_DIR');
  writeFileSync(`${dir}/server.pem`, readFileSync(`${dir}/${cert}.pem`)); // in place: the container mounts the directory
  tlsSrc('FLUSH SSL');
}
/** Server-side TLS counters: handshakes started and finished with the source since its start. */
const handshakes = () => {
  const row = (name: string) => Number(tlsSrc(`SHOW GLOBAL STATUS LIKE '${name}'`).split('\t')[1]);
  return { started: row('Ssl_accepts'), finished: row('Ssl_finished_accepts') };
};
/** Login events (successful or refused) of any account but root recorded by the plain source: its general log, table output. */
const loginCount = (run: (s: string) => string) =>
  Number(
    run(
      "SELECT COUNT(*) FROM mysql.general_log WHERE command_type='Connect' AND CONVERT(user_host USING utf8) NOT LIKE '%root%'",
    ),
  );
const plainConnects = () => loginCount(plainSrc);
const tlsLogins = () => loginCount(tlsSrc);

async function fillSource(page: Page, host: string, port: string, tls: 'verify' | 'disable') {
  await page.getByLabel('Host', { exact: true }).fill(host);
  await page.getByLabel('Port', { exact: true }).fill(port);
  await page.getByLabel('Datenbank', { exact: true }).fill(env('E2E_LEGACY_DB'));
  await page.getByLabel('Benutzer', { exact: true }).fill(env('E2E_LEGACY_USER'));
  await page.getByLabel('Passwort', { exact: true }).fill(env('E2E_LEGACY_PASSWORD'));
  await page.getByLabel('TLS-Modus').selectOption(tls);
}

/** Runs the check and returns what the page says: 'ok' or the text of the error notice. */
async function check(page: Page, host: string, port: string, tls: 'verify' | 'disable') {
  resetBudget();
  await fillSource(page, host, port, tls);
  await page.getByRole('button', { name: /^(Verbindung prüfen|Erneut prüfen)$/ }).click();
  const ok = page.getByText(/Nur lesender Zugang geprüft/);
  const err = page.getByRole('alert').first();
  await expect(ok.or(err)).toBeVisible({ timeout: 60_000 });
  if (await ok.isVisible()) return 'ok';
  return (await err.innerText()).split('\n')[0].trim(); // the notice carries a "retry" button after the text
}

test('source check over real TLS: trusted, wrong host, unknown CA, expired, no TLS, disable, import', async ({
  page,
  context,
}) => {
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
  const host = env('E2E_SRC_HOST');
  const port = env('E2E_SRC_PORT');
  const secrets = [env('E2E_LEGACY_PASSWORD'), env('E2E_DB_PASSWORD')];
  const seen: string[] = [];
  const say = (name: string, text: string) => {
    console.log(`RESULT ${name}: ${text}`);
    seen.push(text);
  };

  tlsSrc("SET GLOBAL log_output='TABLE'; SET GLOBAL general_log=1");

  // 1. certificate of a CA the app trusts, matching host name -> success; the source itself counts a finished TLS handshake
  serve('good');
  let before = handshakes();
  const good = await check(page, host, port, 'verify');
  say('verify/good', good);
  expect(good).toBe('ok');
  const after = handshakes();
  expect(after.finished).toBeGreaterThan(before.finished);
  expect(after.started - before.started).toBe(after.finished - before.finished); // every handshake started also finished
  console.log(
    `TLS evidence: source counted ${after.finished - before.finished} finished TLS handshake(s)`,
  );

  const loginsAtStart = tlsLogins(); // the successful check above logged in; from here on no login may appear until step 7

  // 2. certificate for another host name
  serve('wronghost');
  before = handshakes();
  const wrongHost = await check(page, host, port, 'verify');
  say('verify/wronghost', wrongHost);
  expect(wrongHost).toContain(HOSTNAME);
  expect(handshakes().started).toBeGreaterThan(before.started); // the failure happened IN the TLS handshake, not before it

  // 3. certificate of a CA the app does not know
  serve('unknownca');
  before = handshakes();
  const unknownCa = await check(page, host, port, 'verify');
  say('verify/unknownca', unknownCa);
  expect(unknownCa).toContain(UNTRUSTED);
  expect(handshakes().started).toBeGreaterThan(before.started); // the failure happened IN the TLS handshake, not before it

  // 4. expired certificate
  serve('expired');
  before = handshakes();
  const expired = await check(page, host, port, 'verify');
  say('verify/expired', expired);
  expect(expired).toContain(EXPIRED);
  expect(handshakes().started).toBeGreaterThan(before.started); // the failure happened IN the TLS handshake, not before it
  serve('good');
  expect(tlsLogins()).toBe(loginsAtStart); // no login of the account in any failure case, diagnosis connections included

  // 5. source without TLS while verify is required: aborted BEFORE any credential is sent. The source itself recorded no connection event of the
  // account (its general log lists successful and refused logins); the control below shows that the log would have shown one.
  const plainHost = env('E2E_PLAIN_HOST');
  const plainPort = env('E2E_PLAIN_PORT');
  const connectsBefore = plainConnects();
  const noTls = await check(page, plainHost, plainPort, 'verify');
  say('verify/no-tls', noTls);
  expect(noTls).toContain('kein TLS');
  expect(plainConnects()).toBe(connectsBefore);

  // 6. tls=disable (this stack runs with FORM_ALLOW_INSECURE_DEV=1): works, and the same log now shows the account -> the check in 5 was meaningful
  const disabled = await check(page, plainHost, plainPort, 'disable');
  say('disable/plain', disabled);
  expect(disabled).toBe('ok');
  expect(plainConnects()).toBeGreaterThan(connectsBefore);

  // 7. import over the TLS source (tls=verify, trusted certificate): check, mapping to a new customer, dry run, import; the SOURCE counts the handshakes
  serve('good');
  before = handshakes();
  expect(await check(page, host, port, 'verify')).toBe('ok');
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill('TLS Umstieg GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0'); // a dry run leaves nothing behind
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(target('SELECT COUNT(*) FROM forms')).toBe(
    tlsSrc('SELECT COUNT(*) FROM legacy.formulare'),
  );
  expect(target('SELECT COUNT(*) FROM submissions')).toBe(
    tlsSrc('SELECT COUNT(*) FROM legacy.anfragen'),
  );
  const jobs = handshakes();
  expect(tlsLogins()).toBeGreaterThan(loginsAtStart); // control: the same log does show the account once the certificate is accepted
  expect(jobs.finished).toBeGreaterThanOrEqual(before.finished + 3); // check, dry run and import each opened their own TLS session
  console.log(
    `TLS evidence import: ${jobs.finished - before.finished} finished TLS handshakes during check, dry run and import`,
  );

  // No credential in any text the page showed
  for (const text of seen) for (const s of secrets) expect(text).not.toContain(s);
  const body = await page.locator('body').innerText();
  for (const s of secrets) expect(body).not.toContain(s);
  const audit = target(
    "SELECT GROUP_CONCAT(CONCAT(action_code,' ',safe_details_json) ORDER BY occurred_at SEPARATOR '|') FROM audit_events WHERE action_code LIKE 'migration.source.test%'",
  );
  console.log(`AUDIT ${audit}`);
  for (const s of secrets) expect(audit).not.toContain(s);
  for (const code of ['source_cert_hostname', 'source_cert_untrusted', 'source_cert_expired'])
    expect(audit.split(code).length - 1).toBe(1); // cause code only
  expect(audit).not.toContain('source_failed');
  expect(audit.split('source_no_tls').length - 1).toBe(1);
  if (EXPECT_WRONG) expect(good).toBe('definitely not this');
});
