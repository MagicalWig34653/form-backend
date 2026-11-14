import { execFileSync, spawn } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { test, expect, type Page } from '@playwright/test';
import { resetBudget, sql, unlockWithPasskey, uuidBin } from './unlock-helpers';
import {
  addAuthenticator,
  addField,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';
import {
  exactlyOneMail,
  expectAttachments,
  expectEnvelope,
  mailpit,
  totalMessages,
} from './mail-helpers';

// Real end-to-end of the failure paths of the mail chain, from the PHP SDK to the mail in a real SMTP server (Mailpit):
//  1. busy server: all ingest slots taken, the SDK waits on 503 ingest_busy + Retry-After and every
//     submission still arrives as EXACTLY ONE mail with its attachment byte for byte (AF71CA8A);
//  2. a field value above the 10 MiB mail limit: the mail is delivered shortened ("gekürzt"), the submission is stored in full, one mail (80EF8B1E);
//  3. mail server down: submission accepted, delivery waits for the manual resend, server back, "Erneut senden" in the PWA -> exactly one mail,
//     attachments byte for byte.
// Synthetic data only.

const PARALLEL = 3;
const BUSY_BYTES = 3_000_000;
const SLOTS = 16; // IngestGate: 16 submissions in flight per replica
const HOLD_SECONDS = 6; // the SDK waits Retry-After: 1 per attempt, so it must pause several times

async function publish(page: Page) {
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel(/Ich habe (den Entwurf|die Änderungen) geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
}

type Sent = { id: string; pauses: number; http: string; files: { sha: string; name: string }[] };

function parse(out: string): Sent {
  const lines = out.trim().split('\n');
  return {
    id: lines[0]!,
    pauses: Number(/^pauses (\d+)$/.exec(lines[1]!)![1]),
    http: lines[2]!.slice(5),
    files: lines.slice(3).map((l) => ({ sha: l.slice(0, 64), name: l.slice(65) })),
  };
}

function driverArgs(credentials: string, marker: string, mode: string, bytes?: number): string[] {
  return [
    '-d',
    'memory_limit=1G',
    env('E2E_SUBMIT_DRIVER'),
    credentials,
    env('E2E_PUBLIC_URL'),
    marker,
    marker,
    mode,
    ...(bytes ? [String(bytes)] : []),
  ];
}

function sendAsync(credentials: string, marker: string, bytes: number): Promise<Sent> {
  return new Promise((resolve, reject) => {
    const child = spawn('php', driverArgs(credentials, marker, 'busy', bytes));
    let out = '';
    let err = '';
    child.stdout.on('data', (d: Buffer) => (out += d.toString()));
    child.stderr.on('data', (d: Buffer) => (err += d.toString()));
    child.on('close', (code) =>
      code === 0
        ? resolve(parse(out))
        : reject(new Error(`SDK submit ${marker} rc=${code}: ${err}${out}`)),
    );
  });
}

const sendSync = (credentials: string, marker: string, mode: string): Sent =>
  parse(
    execFileSync('php', driverArgs(credentials, marker, mode), {
      maxBuffer: 1 << 20,
      timeout: 180_000,
    }).toString(),
  );

const docker = (...args: string[]) => execFileSync('docker', args, { encoding: 'utf8' });

test('busy server, oversized field and mail outage: one mail per submission, nothing lost', async ({
  page,
  context,
}) => {
  test.setTimeout(1_500_000);
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  await createCustomer(page, 'E2E Kunde');
  await createForm(page, 'Kontakt');
  await page.getByRole('link', { name: 'Felder', exact: true }).click();
  await addField(page, 'email', 'E-Mail', 'email');
  await addField(page, 'vorname', 'Vorname', 'text');
  await addField(page, 'anliegen', 'Anliegen', 'text');
  const formUrl = /^(.*\/f\/[0-9a-f-]{36})/.exec(new URL(page.url()).pathname)![1]!;

  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Verbindung anlegen' }).first().click();
  await page.getByLabel('Name', { exact: true }).fill('Mailpit');
  await page.getByLabel('Server').fill('127.0.0.1');
  await page.getByLabel('Port').fill(env('E2E_MAILPIT_SMTP'));
  await page.locator('#conn-security').selectOption('plain');
  await page.getByRole('button', { name: 'Verbindung anlegen' }).last().click();
  await expect(page.getByText('Die Verbindung wurde angelegt.')).toBeVisible();
  await page.getByRole('button', { name: 'Aktionen für Mailpit' }).click();
  await page.getByRole('menuitem', { name: 'Kunden zuweisen' }).click();
  await page.getByLabel('E2E Kunde').check();
  await page.getByRole('button', { name: 'Zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();

  await page.goto(`${formUrl}/mail`);
  await page.getByLabel('Versandverbindung').selectOption({ label: 'Mailpit (SMTP-Server)' });
  await page.getByRole('button', { name: 'Versandweg zuweisen' }).click();
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('formular@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await expect(page.locator('#org-content option:checked')).toHaveText('Mit allen Angaben');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await publish(page);

  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const credentials = `${env('E2E_TMP')}/credentials.json`;
  writeFileSync(credentials, file, { mode: 0o600 });

  // 1. busy: SLOTS stalled uploads (head sent, body never finished) take every ingest slot of the replica. PARALLEL signed SDK submissions of 3 MB are refused at
  // once with 503 ingest_busy + Retry-After: 1; the SDK must wait and retry with the same idempotency key until the slots are free again: all arrive,
  // each as ONE mail, no duplicate submission.
  const formId = (JSON.parse(file) as { formId: string }).formId;
  const holder = spawn('python3', [
    env('E2E_HOLD_SCRIPT'),
    env('E2E_PUBLIC_URL').split(':').pop()!,
    '127.0.0.1',
    formId,
    String(SLOTS),
    '1000000',
    String(HOLD_SECONDS),
  ]);
  await new Promise<void>((resolve, reject) => {
    let said = '';
    holder.stdout.on('data', (d: Buffer) => {
      said += d.toString();
      if (said.includes('held')) resolve();
    });
    holder.on('close', () => reject(new Error(`holder could not take the slots: ${said}`)));
  });
  const t0 = Date.now();
  const results = await Promise.all(
    Array.from({ length: PARALLEL }, (_, i) =>
      sendAsync(credentials, `BUSY-${i}-4711`, BUSY_BYTES),
    ),
  );
  expect(new Set(results.map((r) => r.id)).size).toBe(PARALLEL);
  const pauses = results.reduce((n, r) => n + r.pauses, 0);
  console.log(`busy: ${pauses} SDK pauses on 503 Retry-After over ${PARALLEL} submissions`);
  expect(
    pauses,
    `the load must have provoked at least one 503 + Retry-After wait (submissions took ${Math.round((Date.now() - t0) / 1000)} s; ${results.map((r) => r.http).join(' | ')})`,
  ).toBeGreaterThan(0);
  expect(sql(`SELECT COUNT(*) FROM submissions`)).toBe(String(PARALLEL)); // retries created no second submission
  for (const [i, r] of results.entries()) {
    const m = await exactlyOneMail(r.id, { timeoutMs: 300_000, settleMs: 500 });
    expectEnvelope(m, 'Neue Einsendung: Kontakt');
    expect(m.Text).toContain(`Vorname: Vorname-BUSY-${i}-4711`);
    await expectAttachments(m, [{ ...r.files[0]!, size: BUSY_BYTES }]);
  }
  await new Promise((r) => setTimeout(r, 3000));
  expect(await totalMessages()).toBe(PARALLEL); // no duplicate, nothing stray
  expect(
    sql(
      `SELECT state, COUNT(*) FROM mail_deliveries WHERE mail_kind = 'organisation' GROUP BY state`,
    ),
  ).toMatch(new RegExp(`^smtp-accepted\\s+${PARALLEL}$`));

  // 2. field value of 11 MiB (> 10 MiB mail limit): shortened mail, complete submission, one mail
  const field = sendSync(credentials, 'FIELD-4712', 'field');
  const fm = await exactlyOneMail(field.id, { timeoutMs: 180_000 });
  expectEnvelope(fm, 'Neue Einsendung: Kontakt');
  expect(fm.Text).toContain('gekürzt');
  expect(fm.Text).toContain('Anliegen: Anliegen-FIELD-4712-');
  expect(fm.Text).toContain('Vorname: Vorname-FIELD-4712');
  expect(fm.Text.length).toBeLessThan(10 * 1024 * 1024);
  expect(fm.Text).toContain(`Kennung: ${field.id}`);
  expect(sql(`SELECT COUNT(*) FROM submissions WHERE id = ${uuidBin(field.id)}`)).toBe('1');
  expect(
    Number(
      sql(
        `SELECT MAX(byte_count) FROM stored_objects WHERE submission_id = ${uuidBin(field.id)} AND object_role = 'data'`,
      ),
    ),
  ).toBeGreaterThan(11 * 1024 * 1024); // the stored submission is complete, only the mail is shortened
  expect(
    sql(
      `SELECT state FROM mail_deliveries WHERE submission_id = ${uuidBin(field.id)} AND mail_kind = 'organisation'`,
    ),
  ).toBe('smtp-accepted');
  expect(await totalMessages()).toBe(PARALLEL + 1);

  // 3. outage: mail server down -> submission accepted, delivery waits; server back -> manual resend -> exactly one mail with the files
  docker('stop', env('E2E_MAILPIT_CONTAINER'));
  const down = sendSync(credentials, 'DOWN-4713', 'files');
  expect(sql(`SELECT COUNT(*) FROM submissions WHERE id = ${uuidBin(down.id)}`)).toBe('1');
  await expect
    .poll(
      () =>
        sql(
          `SELECT state FROM mail_deliveries WHERE submission_id = ${uuidBin(down.id)} AND mail_kind = 'organisation'`,
        ),
      { timeout: 60_000 },
    )
    .toBe('waiting-manual');
  console.log(
    'outage delivery: ' +
      sql(
        `SELECT state, attempts, IFNULL(last_error_code,'-') FROM mail_deliveries WHERE submission_id = ${uuidBin(down.id)} AND mail_kind = 'organisation'`,
      ),
  );
  docker('start', env('E2E_MAILPIT_CONTAINER'));
  await expect
    .poll(async () => (await fetch(mailpit('/api/v1/info')).catch(() => null))?.ok ?? false, {
      timeout: 60_000,
    })
    .toBe(true);
  expect(await totalMessages()).toBe(0); // fresh Mailpit, and no mail was delivered behind our back
  await new Promise((r) => setTimeout(r, 3000));
  expect(await totalMessages()).toBe(0);

  resetBudget();
  // in-app navigation only (a page load locks the RAM-only keyring): unlock with the passkey first
  await unlockWithPasskey(page);
  await expect(async () => {
    await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
    await page.getByRole('link', { name: 'Öffnen: E2E Kunde' }).click({ timeout: 15_000 });
  }).toPass({ timeout: 75_000 });
  await page
    .getByRole('link', { name: /Kontakt/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  const rows = page.getByRole('button', { name: /^Aktionen für Einsendung/ });
  await expect(rows.first()).toBeVisible({ timeout: 60_000 });
  // the outage submission is the newest one (list is newest first)
  await expect(async () => {
    await rows.first().click();
    await page.getByRole('menuitem', { name: 'Öffnen' }).click({ timeout: 5_000 });
    await expect(page.getByRole('dialog').getByText('Vorname-DOWN-4713')).toBeVisible({
      timeout: 5_000,
    });
  }).toPass({ timeout: 60_000 });
  const detail = page.getByRole('dialog');
  await detail.getByRole('button', { name: 'Erneut senden' }).click();
  await expect(detail.getByText('Der Versand wurde gestartet.')).toBeVisible();
  const again = await exactlyOneMail(down.id, { timeoutMs: 120_000 });
  expectEnvelope(again, 'Neue Einsendung: Kontakt');
  expect(again.Text).toContain('Vorname: Vorname-DOWN-4713');
  await expectAttachments(again, down.files);
  expect(again.Text).not.toContain('nicht beigefügt');
  expect(await totalMessages()).toBe(1); // the resend produced exactly one mail
  expect(
    sql(
      `SELECT state, IFNULL(last_error_code,'-') FROM mail_deliveries WHERE submission_id = ${uuidBin(down.id)} AND mail_kind = 'organisation'`,
    ),
  ).toMatch(/^smtp-accepted\s+-$/);
});
