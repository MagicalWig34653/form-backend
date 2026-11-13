import { test, expect, type Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { addAuthenticator, env, loginAndSecure, registerPasskey, toOverview } from './helpers';
import { resetBudget, source, target } from './migration-helpers';

// Umstieg verification through the browser against the REAL backend binary, a real target MariaDB and a real legacy MariaDB loaded from the
// synthetic dump. No mocks; orchestrated by backend/e2e-migration-verify.sh.
// Chain: source check -> mapping (new customer) -> dry run -> import -> step "Prüfung": "Altzugriff entfernen" is refused (409) before the
// confirmations -> decryption probe with a WRONG key fails locally and confirms nothing -> probe with the synthetic old key (seed 0x11) is
// decrypted locally in the browser, confirmed, local test message confirmed (only ciphertext hashes stored) -> "Altzugriff entfernen":
// source credentials gone (managed_secrets, source_json), imported data and report unchanged (fingerprint before = after), no source
// credential in the target dump, a second removal is refused, probe/route refuse a closed job.
// The "test message" of the product is a locally encrypted ciphertext (ADR 0033), not a mail: no mail server is involved.

// Synthetic old keys of RehearsalSource (base64url of 32 x seed), by key id: alphaOld (0x10, kid a6077815...), alphaActive (0x11, kid d19bf3f0...).
const OLD_KEYS: Record<string, string> = {
  a6077815bba8b14c: Buffer.alloc(32, 0x10).toString('base64url'),
  d19bf3f082782c87: Buffer.alloc(32, 0x11).toString('base64url'),
};
const WRONG_KEY = 'QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI'; // 32 x 0x42, not an old key

function dumpTarget(): string {
  return execFileSync(
    'docker',
    [
      'exec',
      '-e',
      `MYSQL_PWD=${env('E2E_DB_PASSWORD')}`,
      env('E2E_DB_CONTAINER'),
      'mariadb-dump',
      '-uroot',
      '--skip-extended-insert',
      '--hex-blob',
      'e2e',
    ],
    { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 },
  );
}

/** Content fingerprint of everything imported plus the job report (not the credentials, not timestamps). */
function fingerprint(): string {
  return [
    target('SELECT COUNT(*), COUNT(DISTINCT customer_id) FROM forms'),
    target('SELECT COUNT(*) FROM submissions'),
    target(
      'SELECT COUNT(*), MD5(GROUP_CONCAT(HEX(ciphertext_sha256) ORDER BY id)) FROM stored_objects',
    ),
    target('SELECT COUNT(*) FROM customer_key_generations'),
    target('SELECT COUNT(*) FROM data_key_recovery'),
    target(
      "SELECT COUNT(*), MD5(GROUP_CONCAT(CONCAT(source_table,'|',HEX(source_key),'|',target_slot) ORDER BY source_table,source_key,target_slot)) FROM migration_objects",
    ),
    target('SELECT COUNT(*) FROM migration_runs'),
    target('SELECT MD5(report_json) FROM migration_jobs'),
  ].join('\n');
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

test('migration verification: probe, local test message, remove source', async ({
  page,
  context,
}) => {
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  resetBudget();

  // 1. source check, mapping to a new customer, dry run, import
  await checkSource(page);
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill('Verify GmbH');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  const job = () => target('SELECT dry_run, state FROM migration_jobs');
  expect(job()).toBe('0\treview');
  expect(target('SELECT COUNT(*) FROM submissions')).toBe(source('SELECT COUNT(*) FROM anfragen'));
  expect(target('SELECT probe_hash IS NULL, test_hash IS NULL FROM migration_jobs')).toBe('1\t1');

  // the stored source credentials: four managed secrets (host, database, user, password), none readable in the target
  const refs = JSON.parse(target('SELECT source_json FROM migration_jobs')) as Record<
    string,
    string
  >;
  const refValues = [refs.host, refs.database, refs.username, refs.password];
  for (const r of refValues) expect(r).toMatch(/^s1:/);
  expect(refValues.length).toBe(4);
  const secretCount = () =>
    target(
      `SELECT COUNT(*) FROM managed_secrets WHERE ref IN (${refValues.map((r) => `'${r}'`).join(',')})`,
    );
  expect(secretCount()).toBe('4');
  const legacyPw = env('E2E_LEGACY_PASSWORD');
  const legacyUser = env('E2E_LEGACY_USER');
  const beforeDump = dumpTarget();
  expect(beforeDump.includes(legacyPw), 'source password in target dump before removal').toBe(
    false,
  );
  expect(beforeDump.includes(legacyUser), 'source user in target dump before removal').toBe(false);

  // 2. step "Prüfung"
  // the page lands on the step by itself once the import waits for review
  await expect(page.getByRole('heading', { name: 'Prüfung', exact: true }).first()).toBeVisible();
  await expect(page.getByText(/Probe.*offen/i).first()).toBeVisible();

  // 2a. negative (server): "remove source" is refused before probe and test message are confirmed
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Umschaltung', exact: true })).toBeVisible();
  // the page blocks the button and names what is missing ...
  await expect(page.getByRole('button', { name: 'Altzugriff entfernen' })).toBeDisabled();
  await expect(page.getByText('Noch offen: Probe, Testnachricht.')).toBeVisible();
  // ... and the server still refuses with 409 (checked directly), nothing changes
  const jobIdEarly = target(
    'SELECT LOWER(INSERT(INSERT(INSERT(INSERT(HEX(id),9,0,"-"),14,0,"-"),19,0,"-"),24,0,"-")) FROM migration_jobs',
  );
  const sessionEarly = (await (await page.request.get('/admin/api/v1/auth/session')).json()) as {
    csrfToken: string;
  };
  const early = await page.request.post(
    `/admin/api/v1/migration/jobs/${jobIdEarly}/remove-source`,
    {
      headers: { 'X-CSRF-Token': sessionEarly.csrfToken, Origin: new URL(page.url()).origin },
      data: {},
    },
  );
  expect(early.status()).toBe(409);
  expect(job()).toBe('0\treview');
  expect(secretCount()).toBe('4');
  expect(target("SELECT source_json <> '{}' FROM migration_jobs")).toBe('1');
  await page.getByRole('button', { name: 'Zurück' }).click();

  // 2b. negative (browser): a wrong key does not decrypt the sample, nothing is confirmed
  const probeResponse = page.waitForResponse((r) =>
    /\/migration\/jobs\/[^/]+\/probe$/.test(r.url()),
  );
  await page.getByRole('button', { name: 'Entschlüsselungsprobe laden' }).click();
  const wire = ((await (await probeResponse).json()) as { wire: string }).wire;
  const kid = wire.split('|')[1];
  const OLD_KEY = OLD_KEYS[kid];
  expect(OLD_KEY, `sample key id ${kid} is a synthetic old key`).toBeTruthy();
  console.log('PROBE-SAMPLE kid', kid);
  // the page names the key id the sample needs (public identifier)
  await expect(page.getByTestId('migration-probe-kid')).toContainText(kid);
  await page.getByLabel('Privater Altschlüssel').fill(WRONG_KEY);
  await page.getByRole('button', { name: 'Probe lokal entschlüsseln' }).click();
  await expect(page.getByText(/Probe fehlgeschlagen oder abgebrochen/)).toBeVisible();
  expect(target('SELECT probe_hash IS NULL, test_hash IS NULL FROM migration_jobs')).toBe('1\t1');
  expect(
    target("SELECT COUNT(*) FROM audit_events WHERE action_code LIKE 'migration.probe.%'"),
  ).toBe(
    '1', // only the read (GET probe), no confirm/test
  );
  // Remove-source stays refused after the failed probe (server state unchanged).
  expect(job()).toBe('0\treview');

  // 2c. the correct old key: decrypted locally, confirmed by the human, local test message confirmed
  await page.getByLabel('Privater Altschlüssel').fill(OLD_KEY);
  await page.getByRole('button', { name: 'Probe lokal entschlüsseln' }).click();
  await page.getByRole('alertdialog').getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText(/Lokale Entschlüsselung bestätigt/)).toBeVisible();
  const hashes = target('SELECT probe_hash, test_hash FROM migration_jobs').split('\t');
  expect(hashes[0]).toMatch(/^[0-9a-f]{64}$/);
  expect(hashes[1]).toMatch(/^[0-9a-f]{64}$/);
  expect(hashes[0]).not.toBe(hashes[1]); // the test message is a fresh ciphertext
  // probe_hash is the SHA-256 of an imported ciphertext (not of a plaintext); the test message is not stored anywhere
  expect(
    target(
      `SELECT COUNT(*) FROM stored_objects WHERE LOWER(HEX(ciphertext_sha256)) = '${hashes[0]}'`,
    ),
  ).toBe('1');
  expect(
    target(
      `SELECT COUNT(*) FROM stored_objects WHERE LOWER(HEX(ciphertext_sha256)) = '${hashes[1]}'`,
    ),
  ).toBe('0');
  expect(
    target(
      "SELECT GROUP_CONCAT(action_code ORDER BY occurred_at) FROM audit_events WHERE action_code LIKE 'migration.probe.%'",
    ),
  ).toBe('migration.probe.read,migration.probe.confirm,migration.probe.test');
  await expect(page.getByText(/Probe.*bestätigt.*Test.*bestätigt/i).first()).toBeVisible();
  const afterDump = dumpTarget();
  expect(afterDump.includes(OLD_KEY), 'old private key in target dump').toBe(false);
  expect(afterDump.includes('KLARTEXT-MARKER'), 'plaintext marker in target dump').toBe(false);

  // 3. remove source
  const fpBefore = fingerprint();
  resetBudget();
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Umschaltung', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Altzugriff entfernen' })).toBeEnabled();
  await page.getByRole('button', { name: 'Altzugriff entfernen' }).click();
  await expect(page.getByText('Der Altzugriff wurde entfernt.')).toBeVisible();
  // closed job: the page shows the finished state with what was done, and no action
  const closedBox = page.getByTestId('migration-closed');
  await expect(closedBox).toContainText('Umstieg abgeschlossen');
  await expect(closedBox).toContainText('Entschlüsselungsprobe lokal bestätigt.');
  await expect(closedBox).toContainText('Testnachricht lokal bestätigt.');
  await expect(closedBox).toContainText('Die Zugangsdaten zur Quelle sind entfernt.');
  expect(job()).toBe('0\tclosed');
  expect(secretCount()).toBe('0');
  expect(target('SELECT source_json FROM migration_jobs')).toBe('{}');
  expect(fingerprint()).toBe(fpBefore); // imported data, ledger and report unchanged
  const closedDump = dumpTarget();
  expect(closedDump.includes(legacyPw), 'source password in target dump after removal').toBe(false);
  expect(closedDump.includes(legacyUser), 'source user in target dump after removal').toBe(false);
  expect(
    target("SELECT COUNT(*) FROM audit_events WHERE action_code='migration.job.remove-source'"),
  ).toBe('1');

  // 4. no further source access through the job: the page offers no removal any more; the routes refuse a closed job and change nothing
  await expect(page.getByRole('button', { name: 'Altzugriff entfernen' })).toHaveCount(0);
  const jobId = target(
    'SELECT LOWER(INSERT(INSERT(INSERT(INSERT(HEX(id),9,0,"-"),14,0,"-"),19,0,"-"),24,0,"-")) FROM migration_jobs',
  );
  const session = (await (await page.request.get('/admin/api/v1/auth/session')).json()) as {
    csrfToken: string;
  };
  const headers = { 'X-CSRF-Token': session.csrfToken, Origin: new URL(page.url()).origin };
  const base = `/admin/api/v1/migration/jobs/${jobId}`;
  const statuses: Record<string, number> = {};
  for (const action of ['remove-source', 'resume', 'import', 'pause'])
    statuses[action] = (
      await page.request.post(`${base}/${action}`, { headers, data: {} })
    ).status();
  // a delta does not exist any more (ADR 0043): unknown action -> 404 for every job; `rehearse` of a closed job is refused
  statuses.delta = (
    await page.request.post(`${base}/delta`, { headers, data: { dumpSHA256: 'cd'.repeat(32) } })
  ).status();
  statuses.rehearse = (await page.request.post(`${base}/rehearse`, { headers, data: {} })).status();
  statuses.verify = (
    await page.request.post(`${base}/verify`, {
      headers,
      data: { hash: 'ab'.repeat(32), success: true },
    })
  ).status();
  statuses.probe = (await page.request.get(`${base}/probe`)).status();
  console.log('CLOSED-JOB-STATUSES', JSON.stringify(statuses));
  expect(statuses).toEqual({
    'remove-source': 409,
    resume: 409,
    import: 409,
    pause: 409,
    delta: 404,
    rehearse: 409,
    verify: 409,
    probe: 409,
  });
  expect(
    target("SELECT COUNT(*) FROM audit_events WHERE action_code='migration.job.remove-source'"),
  ).toBe('1');
  expect(job()).toBe('0\tclosed');
  expect(secretCount()).toBe('0');
  expect(fingerprint()).toBe(fpBefore);
});
