import { execFileSync } from 'node:child_process';
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
  clearMailbox,
  exactlyOneMail,
  expectAttachments,
  expectEnvelope,
  totalMessages,
} from './mail-helpers';

// Real end-to-end (decision 14.11.2026, ADR 0049): the practice team has no backend access, uploaded files must be IN the team mail. Real binary,
// real MariaDB, real SMTP server (Mailpit), real signed SDK submissions with files. Synthetic data only.

async function publish(page: Page, bump: boolean) {
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  if (bump) {
    await page.getByRole('button', { name: 'Versionsnummer erhöhen' }).click();
    await expect(page.getByText('Die Versionsnummer wurde erhöht.')).toBeVisible();
  }
  await page.getByLabel(/Ich habe (den Entwurf|die Änderungen) geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
}

test('uploaded files travel in the team mail byte for byte (ADR 0049)', async ({
  page,
  context,
}) => {
  test.setTimeout(420_000);
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

  // connection to the real mail server (system administrator), assignment to the customer
  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Verbindung anlegen' }).first().click();
  await page.getByLabel('Name', { exact: true }).fill('Mailpit');
  await page.getByLabel('Server').fill(process.env.E2E_MAILPIT_SMTP_HOST ?? '127.0.0.1');
  await page.getByLabel('Port').fill(env('E2E_MAILPIT_SMTP'));
  await page.locator('#conn-security').selectOption('plain');
  await page.getByRole('button', { name: 'Verbindung anlegen' }).last().click();
  await expect(page.getByText('Die Verbindung wurde angelegt.')).toBeVisible();
  await page.getByRole('button', { name: 'Aktionen für Mailpit' }).click();
  await page.getByRole('menuitem', { name: 'Kunden zuweisen' }).click();
  await page.getByLabel('E2E Kunde').check();
  await page.getByRole('button', { name: 'Zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();

  // Mail tab: sender and recipient only. The content choice is NOT touched and must show the standard.
  await page.goto(`${formUrl}/mail`);
  await page.getByLabel('Versandverbindung').selectOption({ label: 'Mailpit (SMTP-Server)' });
  await page.getByRole('button', { name: 'Versandweg zuweisen' }).click();
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('formular@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await expect(page.locator('#org-content option:checked')).toHaveText('Mit allen Angaben');
  await expect(page.getByRole('alert').filter({ hasText: 'Art. 9' })).toHaveCount(0);
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await publish(page, false);

  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const credentials = `${env('E2E_TMP')}/credentials.json`;
  writeFileSync(credentials, file, { mode: 0o600 });
  const sent = (mode: string, marker: string) => {
    const lines = execFileSync(
      'php',
      [env('E2E_SUBMIT_DRIVER'), credentials, env('E2E_PUBLIC_URL'), marker, marker, mode],
      { maxBuffer: 1 << 20 },
    )
      .toString()
      .trim()
      .split('\n');
    return {
      id: lines[0]!,
      files: lines.slice(1).map((l) => ({ sha: l.slice(0, 64), name: l.slice(65) })),
    };
  };

  // 1. two files, umlauts and special characters in the names: exactly one mail, same bytes, same names
  const multi = sent('multi', 'MULTI-4711');
  const m1 = await exactlyOneMail(multi.id);
  expectEnvelope(m1, 'Neue Einsendung: Kontakt');
  for (const line of ['Vorname: Vorname-MULTI-4711', 'Anliegen: Anliegen-MULTI-4711'])
    expect(m1.Text.replace(/\r\n/g, '\n')).toContain(line);
  await expectAttachments(m1, multi.files);
  for (const a of m1.Attachments) expect(a.ContentType).toBe('application/pdf');
  expect(m1.Text).not.toContain('konnten nicht an diese Mail angehängt werden');
  expect(await totalMessages()).toBe(1);

  // 1b. 3 MB file: exactly one mail, complete, byte for byte
  const mid = sent('mid', 'MID-4710');
  const m1b = await exactlyOneMail(mid.id, { settleMs: 4000 });
  expectEnvelope(m1b, 'Neue Einsendung: Kontakt');
  expect(m1b.Attachments.length).toBe(1);
  await expectAttachments(m1b, [{ ...mid.files[0]!, size: 3_000_000 }]);
  expect(await totalMessages()).toBe(2);

  // 2. 19.9 MB file: exactly one mail, complete, byte for byte
  const big = sent('big', 'BIG-4712');
  const m2 = await exactlyOneMail(big.id, { settleMs: 5000 });
  expectEnvelope(m2, 'Neue Einsendung: Kontakt');
  expect(m2.Attachments.length).toBe(1);
  await expectAttachments(m2, [{ ...big.files[0]!, size: 19_900_000 }]);
  expect(await totalMessages()).toBe(3);

  // 3. total beyond FORM_MAIL_MAX_MB (30): the first file goes, the second is NAMED in the mail text, never lost silently
  const over = sent('over', 'OVER-4713');
  const m3 = await exactlyOneMail(over.id, { settleMs: 5000 });
  expectEnvelope(m3, 'Neue Einsendung: Kontakt');
  await expectAttachments(m3, [over.files[0]!]);
  expect(m3.Text).toContain('zweite-Datei.pdf');
  expect(m3.Text).toContain('nicht an diese Mail angehängt');
  expect(await totalMessages()).toBe(4);

  // 4. manual resend in the PWA (ADR 0049 Nachtrag, parity with ALT): the browser opens the entry, hands over the attachment keys, the server re-attaches the files
  sql(
    `UPDATE mail_deliveries SET state = 'waiting-manual', last_error_code = 'no_connection' WHERE mail_kind = 'organisation' AND submission_id = ${uuidBin(multi.id)}`,
  );
  await clearMailbox();
  resetBudget();
  // in-app navigation only: a page load would lock the keyring (RAM only)
  // the earlier page loads locked the RAM-only keyring: unlock with the passkey (PRF), then back to the entries by in-app navigation
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
  await expect(rows).toHaveCount(4);
  // oldest entry = the first submission (list is newest first); repeat the click path if the list re-renders under the cursor
  await expect(async () => {
    await rows.last().click();
    await page.getByRole('menuitem', { name: 'Öffnen' }).click({ timeout: 5_000 });
  }).toPass({ timeout: 45_000 });
  const detail = page.getByRole('dialog');
  await expect(detail.getByText(`Vorname-MULTI-4711`)).toBeVisible();
  await detail.getByRole('button', { name: 'Erneut senden' }).click();
  await expect(detail.getByText('Der Versand wurde gestartet.')).toBeVisible();
  const again = await exactlyOneMail(multi.id);
  expectEnvelope(again, 'Neue Einsendung: Kontakt');
  await expectAttachments(again, multi.files);
  expect(await totalMessages()).toBe(1); // the resend produced exactly one mail
  expect(again.Text).not.toContain('nicht beigefügt');
  expect(
    sql(
      `SELECT state, IFNULL(last_error_code,'-') FROM mail_deliveries WHERE mail_kind = 'organisation' AND submission_id = ${uuidBin(multi.id)}`,
    ),
  ).toMatch(/^smtp-accepted\s+-$/);
});
