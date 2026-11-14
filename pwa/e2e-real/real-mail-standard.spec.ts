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
import { exactlyOneMail, expectEnvelope, totalMessages } from './mail-helpers';

// Real end-to-end (decision 13.11.2026, ADR 0041): a form whose Mail tab is never touched for the content choice must send ALL fields to the
// team; "Nur Benachrichtigung mit Link" is only sent when chosen. Real binary, real MariaDB, real SMTP server (Mailpit), real signed SDK
// submission. Synthetic data only.

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

  // 1. standard: exactly ONE mail, recipient/sender/subject, every field with label and value
  const id1 = submit('ALLES-4711');
  const full = await exactlyOneMail(id1);
  expectEnvelope(full, 'Neue Einsendung: Kontakt');
  const fullText = full.Text.replace(/\r\n/g, '\n');
  for (const line of [
    'E-Mail: erika@example.org',
    'Vorname: Vorname-ALLES-4711',
    'Anliegen: Anliegen-ALLES-4711',
    `Kennung: ${id1}`,
  ])
    expect(fullText).toContain(line);
  expect(await totalMessages()).toBe(1);

  // 2. explicit choice: only the notification with the link
  await page.goto(`${formUrl}/mail`);
  await page.locator('#org-content').selectOption('notification');
  await expect(page.getByTestId('org-notification-hint')).toBeVisible();
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await publish(page, true);
  const id2 = submit('NUR-LINK-4712');
  const note = await exactlyOneMail(id2);
  expectEnvelope(note, 'Neue Einsendung: Kontakt');
  const noteText = note.Text.replace(/\r\n/g, '\n');
  expect(noteText).toContain(`Kennung: ${id2}`);
  expect(noteText).toContain('/entries');
  expect(noteText).not.toContain('NUR-LINK-4712');
  expect(noteText).not.toContain('erika@example.org');
  expect(await totalMessages()).toBe(2); // one mail per submission, nothing stray
});
