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

// Real end-to-end (decision 13.11.2026, ADR 0041): a form whose Mail tab is never touched for the content choice must send ALL fields to the
// team; "Nur Benachrichtigung mit Link" is only sent when chosen. Real binary, real MariaDB, real SMTP server (Mailpit), real signed SDK
// submission. Synthetic data only.

const mailpit = (path: string) => `http://127.0.0.1:${env('E2E_MAILPIT_API')}${path}`;

async function newestMail(): Promise<{ subject: string; text: string }> {
  for (let i = 0; i < 60; i++) {
    const list = (await (await fetch(mailpit('/api/v1/messages'))).json()) as {
      messages: { ID: string }[];
    };
    if (list.messages.length > 0) {
      const m = (await (
        await fetch(mailpit(`/api/v1/message/${list.messages[0]!.ID}`))
      ).json()) as { Subject: string; Text: string };
      return { subject: m.Subject, text: m.Text.replace(/\r\n/g, '\n') };
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error('no mail arrived');
}

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

test('standard team mail carries all fields; notification only by explicit choice', async ({
  page,
  context,
}) => {
  test.setTimeout(240_000);
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

  const submit = (marker: string) =>
    execFileSync('php', [
      env('E2E_SUBMIT_DRIVER'),
      credentials,
      env('E2E_PUBLIC_URL'),
      marker,
      marker,
    ])
      .toString()
      .trim();

  // 1. standard: every field, with label and value
  const id1 = submit('ALLES-4711');
  const full = await newestMail();
  expect(full.subject).toBe('Neue Einsendung: Kontakt');
  for (const line of [
    'E-Mail: erika@example.org',
    'Vorname: Vorname-ALLES-4711',
    'Anliegen: Anliegen-ALLES-4711',
    `Kennung: ${id1}`,
  ])
    expect(full.text).toContain(line);

  // 2. explicit choice: only the notification with the link
  await page.goto(`${formUrl}/mail`);
  await page.locator('#org-content').selectOption('notification');
  await expect(page.getByTestId('org-notification-hint')).toBeVisible();
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await publish(page, true);
  const id2 = submit('NUR-LINK-4712');
  let note = await newestMail();
  for (let i = 0; i < 20 && !note.text.includes(id2); i++) {
    await new Promise((r) => setTimeout(r, 500));
    note = await newestMail();
  }
  expect(note.text).toContain(`Kennung: ${id2}`);
  expect(note.text).toContain('/entries');
  expect(note.text).not.toContain('NUR-LINK-4712');
  expect(note.text).not.toContain('erika@example.org');
});
