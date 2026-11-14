import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { test, expect, type Page } from '@playwright/test';
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

// Real end-to-end (decision 14.11.2026, ADR 0049): the practice team has no backend access, uploaded files must be IN the team mail. Real binary,
// real MariaDB, real SMTP server (Mailpit), real signed SDK submissions with files. Synthetic data only.

const mailpit = (path: string) => `http://127.0.0.1:${env('E2E_MAILPIT_API')}${path}`;

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
  // Mailpit (real SMTP server): wait for the organisation mail of one submission and return its parts.
  type Att = { PartID: string; FileName: string; ContentType: string; Size: number };
  type Detail = {
    ID: string;
    Subject: string;
    Text: string;
    Attachments: Att[];
    To: { Address: string }[];
  };
  async function teamMail(id: string): Promise<Detail> {
    for (let i = 0; i < 240; i++) {
      const list = (await (await fetch(mailpit('/api/v1/messages?limit=50'))).json()) as {
        messages: { ID: string; To: { Address: string }[] }[];
      };
      for (const m of list.messages) {
        if (!m.To.some((t) => t.Address === 'team@example.org')) continue;
        const d = (await (await fetch(mailpit(`/api/v1/message/${m.ID}`))).json()) as Detail;
        if (d.Text.includes(id)) return d;
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    throw new Error('team mail did not arrive');
  }
  async function partSha256(d: Detail, a: Att): Promise<string> {
    const res = await fetch(mailpit(`/api/v1/message/${d.ID}/part/${a.PartID}`));
    return createHash('sha256')
      .update(Buffer.from(await res.arrayBuffer()))
      .digest('hex');
  }
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

  // 1. two files, umlauts and special characters in the names: same bytes, same names
  const multi = sent('multi', 'MULTI-4711');
  const m1 = await teamMail(multi.id);
  expect(m1.Subject).toBe('Neue Einsendung: Kontakt');
  expect(m1.Attachments.map((a) => a.FileName).sort()).toEqual(
    multi.files.map((f) => f.name).sort(),
  );
  for (const f of multi.files) {
    const a = m1.Attachments.find((x) => x.FileName === f.name)!;
    expect(a.ContentType).toBe('application/pdf');
    expect(await partSha256(m1, a)).toBe(f.sha);
  }
  expect(m1.Text).not.toContain('konnten nicht an diese Mail angehängt werden');

  // 2. 19.9 MB file: complete, byte for byte
  const big = sent('big', 'BIG-4712');
  const m2 = await teamMail(big.id);
  expect(m2.Attachments.length).toBe(1);
  expect(m2.Attachments[0]!.Size).toBe(19_900_000);
  expect(await partSha256(m2, m2.Attachments[0]!)).toBe(big.files[0]!.sha);

  // 3. total beyond FORM_MAIL_MAX_MB (30): the first file goes, the second is NAMED in the mail text, never lost silently
  const over = sent('over', 'OVER-4713');
  const m3 = await teamMail(over.id);
  expect(m3.Attachments.map((a) => a.FileName)).toEqual(['gross.pdf']);
  expect(await partSha256(m3, m3.Attachments[0]!)).toBe(over.files[0]!.sha);
  expect(m3.Text).toContain('zweite-Datei.pdf');
  expect(m3.Text).toContain('nicht an diese Mail angehängt');
});
