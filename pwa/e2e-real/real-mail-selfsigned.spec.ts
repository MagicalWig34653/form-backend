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

// Real end-to-end (ADR 0044): the mail server (Mailpit, STARTTLS) presents a self-signed certificate. A connection without the option
// fails with the named TLS error; the same server with "Eigene/selbstsignierte Zertifikate erlauben" works (connection test and a real
// signed SDK submission -> mail in Mailpit); switching the check back on fails again. Synthetic data only.

const mailpit = (path: string) => `http://127.0.0.1:${env('E2E_MAILPIT_API')}${path}`;
const TLS_FAILED = 'Die verschlüsselte Verbindung konnte nicht hergestellt werden.';

async function messages(): Promise<{ ID: string }[]> {
  const list = (await (await fetch(mailpit('/api/v1/messages'))).json()) as {
    messages: { ID: string }[];
  };
  return list.messages;
}

async function createConnection(page: Page, name: string, selfSigned: boolean) {
  await page.getByRole('button', { name: 'Verbindung anlegen' }).first().click();
  await page.getByLabel('Name', { exact: true }).fill(name);
  await page.getByLabel('Server').fill('127.0.0.1');
  await page.getByLabel('Port').fill(env('E2E_MAILPIT_SMTP'));
  await page.locator('#conn-security').selectOption('starttls');
  const box = page.getByLabel('Eigene/selbstsignierte Zertifikate erlauben');
  await expect(box).not.toBeChecked();
  if (selfSigned) {
    await box.check();
    await expect(page.getByText(/Mails können abgefangen werden/)).toBeVisible();
  }
  await page.getByRole('button', { name: 'Verbindung anlegen' }).last().click();
  await expect(page.getByText('Die Verbindung wurde angelegt.')).toBeVisible();
}

const row = (page: Page, name: string) =>
  page.locator('li').filter({ has: page.getByText(name, { exact: true }) });

async function runCheck(page: Page, name: string) {
  await row(page, name)
    .getByRole('button', { name: /^(Testen|Erneut prüfen)/ })
    .click();
}

test('self-signed option per connection: fails when verifying, works with the option', async ({
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

  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();

  // 1. default: certificate is checked, the self-signed server is refused with a named error
  await createConnection(page, 'Mailpit-geprüft', false);
  await expect(page.getByText('Zertifikat wird nicht geprüft')).toHaveCount(0);
  await runCheck(page, 'Mailpit-geprüft');
  await expect(page.getByText(TLS_FAILED).first()).toBeVisible();

  // 2. explicit option: marked in the list, the check passes
  await createConnection(page, 'Mailpit-eigenes-Zertifikat', true);
  await expect(page.getByText('Zertifikat wird nicht geprüft')).toHaveCount(1);
  await runCheck(page, 'Mailpit-eigenes-Zertifikat');
  await expect(page.getByText('Verbindung in Ordnung')).toBeVisible();

  // assign to the customer and use it for the form
  await page.getByRole('button', { name: 'Aktionen für Mailpit-eigenes-Zertifikat' }).click();
  await page.getByRole('menuitem', { name: 'Kunden zuweisen' }).click();
  await page.getByLabel('E2E Kunde').check();
  await page.getByRole('button', { name: 'Zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();
  await page.goto(`${formUrl}/mail`);
  await page
    .getByLabel('Versandverbindung')
    .selectOption({ label: 'Mailpit-eigenes-Zertifikat (SMTP-Server)' });
  await page.getByRole('button', { name: 'Versandweg zuweisen' }).click();
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('formular@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('status').filter({ hasText: /Gespeichert/ })).toBeVisible();
  await page.getByRole('link', { name: 'Veröffentlichen', exact: true }).click();
  await page.getByLabel(/Ich habe (den Entwurf|die Änderungen) geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText(/Veröffentlicht/).first()).toBeVisible();
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const credentials = `${env('E2E_TMP')}/credentials.json`;
  writeFileSync(credentials, file, { mode: 0o600 });
  expect(await messages()).toHaveLength(0);
  const id = execFileSync('php', [
    env('E2E_SUBMIT_DRIVER'),
    credentials,
    env('E2E_PUBLIC_URL'),
    'SELBST-4713',
    'SELBST-4713',
  ])
    .toString()
    .trim();
  let text = '';
  for (let i = 0; i < 60 && !text; i++) {
    const list = await messages();
    if (list.length > 0) {
      const m = (await (await fetch(mailpit(`/api/v1/message/${list[0]!.ID}`))).json()) as {
        Text: string;
      };
      text = m.Text;
    } else await new Promise((r) => setTimeout(r, 500));
  }
  expect(text).toContain(`Kennung: ${id}`);

  // 3. switching back: verified again, the self-signed server is refused again
  await page.getByRole('link', { name: 'Verbindungen', exact: true }).first().click();
  await expect(page.getByText('Zertifikat wird nicht geprüft')).toHaveCount(1);
  await page.getByRole('button', { name: 'Aktionen für Mailpit-eigenes-Zertifikat' }).click();
  await page.getByRole('menuitem', { name: 'Zertifikatsprüfung wieder einschalten' }).click();
  await expect(
    page.getByText('Das Zertifikat dieses Mailservers wird wieder geprüft.'),
  ).toBeVisible();
  await expect(page.getByText('Zertifikat wird nicht geprüft')).toHaveCount(0);
  await runCheck(page, 'Mailpit-eigenes-Zertifikat');
  await expect(page.getByText(TLS_FAILED).first()).toBeVisible();
});
