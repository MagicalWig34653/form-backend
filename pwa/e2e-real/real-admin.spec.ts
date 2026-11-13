import { generateKeyPairSync } from 'node:crypto';
import { test, expect, type BrowserContext, type Page } from '@playwright/test';

// Whole administration path in a real browser against the real backend + MariaDB (skipped; backend/e2e-admin.sh was removed, superseded by real-setup.spec.ts via backend/e2e-setup.sh):
// login → customer → form → draft fields → customer key → publish (client-side hash must equal the server's) →
// second revision + version bump → SDK credentials → connection → mail configuration.
const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

async function login(page: Page, context: BrowserContext): Promise<void> {
  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  await cdp.send('WebAuthn.addCredential', {
    authenticatorId,
    credential: {
      credentialId: env('E2E_CREDENTIAL_ID_B64'),
      isResidentCredential: true,
      rpId: env('E2E_RP_ID'),
      privateKey: env('E2E_PRIVATE_KEY_B64'),
      userHandle: env('E2E_USER_HANDLE_B64'),
      signCount: 0,
    },
  });
  await page.goto('/login');
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
}

async function addField(page: Page, name: string, label: string, kind: string): Promise<void> {
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Technischer Name').fill(name);
  await page.getByLabel('Beschriftung').fill(label);
  await page.getByLabel('Art').selectOption(kind);
  await page.getByRole('button', { name: 'Speichern' }).click();
  await expect(page.locator('li', { hasText: name }).first()).toBeVisible();
}

async function publish(page: Page): Promise<void> {
  await page.getByRole('tab', { name: 'Veröffentlichen' }).click();
  await page.getByLabel(/Ich habe den Entwurf geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
}

// Superseded by real-setup.spec.ts: creating forms now requires the invisible key setup (PRF + recovery code), which a seeded
// account without PRF cannot do. The full path (key setup, customer, form, fields, publish, SDK credentials) lives there.
test.skip('administration: from login to a published form with mail and SDK credentials', async ({
  page,
  context,
}) => {
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await login(page, context);
  await expect(page).toHaveURL(/\/t$/);
  await expect(page.getByText('Angemeldet als e2e-user')).toBeVisible();

  // customer
  await page.getByLabel('Name des Kunden').fill('E2E Kunde');
  await page.getByRole('button', { name: 'Kunden anlegen' }).click();
  await expect(page.getByRole('heading', { name: 'Formulare' })).toBeVisible();
  const tenantUrl = page.url();

  // form
  await page.getByLabel('Name des Formulars').fill('Kontakt');
  await page.getByRole('button', { name: 'Formular anlegen' }).click();
  await expect(page.getByRole('heading', { name: 'Kontakt' })).toBeVisible();
  await expect(
    page.getByText('Noch nicht veröffentlicht.', { exact: false }).first(),
  ).toBeVisible();

  // draft and fields (every edit is restamped client-side and saved at once)
  await page.getByRole('tab', { name: 'Felder' }).click();
  await expect(page.locator('li', { hasText: 'nachricht' })).toBeVisible();
  await addField(page, 'email', 'E-Mail', 'email');
  await addField(page, 'vorname', 'Vorname', 'text');

  // invalid names are refused before the request
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Technischer Name').fill('a b');
  await page.getByLabel('Beschriftung').fill('X');
  await page.getByRole('button', { name: 'Speichern' }).click();
  await expect(page.getByText('Der Name ist ungültig.')).toBeVisible();
  await page.getByRole('button', { name: 'Abbrechen' }).click();

  // title
  await page.getByRole('tab', { name: 'Überblick' }).click();
  await page.getByLabel('Titel des Formulars').fill('Kontaktformular');
  await page.getByRole('button', { name: 'Titel speichern' }).click();
  await expect(page.getByText('Gespeichert.')).toBeVisible();

  // customer key (an X25519 public key generated here, the private half is discarded)
  const { publicKey } = generateKeyPairSync('x25519');
  const raw = Buffer.from(String(publicKey.export({ format: 'jwk' }).x), 'base64url');
  expect(raw.length).toBe(32);
  await page.getByRole('tab', { name: 'Schlüssel & SDK' }).click();
  await page.getByLabel(/Öffentlicher Schlüssel/).fill(raw.toString('base64url'));
  await page.getByRole('button', { name: 'Schlüssel hinterlegen' }).click();
  await expect(page.getByText('Der Kundenschlüssel wurde hinterlegt.')).toBeVisible();

  // first release: the server recomputes the hash of what the browser stamped
  await publish(page);
  await expect(page.getByText('Veröffentlicht: Version')).toBeVisible();

  // a second revision of the published form: edit, bump versions, publish again
  await page.getByRole('tab', { name: 'Überblick' }).click();
  await page
    .getByRole('button', { name: 'Neuen Entwurf aus der veröffentlichten Version beginnen' })
    .click();
  await expect(page.getByText('Stand 1')).toBeVisible();
  await page.getByRole('tab', { name: 'Felder' }).click();
  await addField(page, 'telefon', 'Telefon', 'text');
  await page.getByRole('tab', { name: 'Veröffentlichen' }).click();
  await page.getByRole('button', { name: 'Versionsnummer erhöhen' }).click();
  await expect(page.getByText('Die Versionsnummer wurde erhöht.')).toBeVisible();
  await page.getByLabel(/Ich habe den Entwurf geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText('Veröffentlicht: Version')).toBeVisible();

  // SDK credentials are shown once and carry the form's ids
  await page.getByRole('tab', { name: 'Schlüssel & SDK' }).click();
  await page.getByRole('button', { name: 'Neue SDK-Zugangsdaten erzeugen' }).click();
  const file = await page.getByLabel('Dateiinhalt für die Zugangsdatei').inputValue();
  const creds = JSON.parse(file) as Record<string, string>;
  expect(creds.signingSeed).toMatch(/^[A-Za-z0-9_-]{43}$/);
  expect(page.url()).toContain(creds.formId);
  await page.reload();
  await page.getByRole('tab', { name: 'Schlüssel & SDK' }).click();
  await expect(page.getByLabel('Dateiinhalt für die Zugangsdatei')).toHaveCount(0);

  // connection (system administrator), assignment, mail configuration
  await page.getByRole('link', { name: 'Verbindungen' }).click();
  await page.getByLabel('Name', { exact: true }).fill('Test-SMTP');
  await page.getByLabel('Server').fill('mail.example.org');
  await page.getByLabel('Port').fill('587');
  await page.getByRole('button', { name: 'Verbindung anlegen' }).click();
  await expect(page.getByText('Die Verbindung wurde angelegt.')).toBeVisible();
  await page.getByLabel(/^Kunden zuweisen: Test-SMTP/).selectOption({ label: 'E2E Kunde' });
  await page.getByRole('button', { name: 'Kunden zuweisen', exact: true }).click();
  await expect(page.getByText('Zugewiesen.')).toBeVisible();

  await page.goto(tenantUrl);
  await page.getByRole('link', { name: /Kontakt/ }).click();
  await page.getByRole('tab', { name: 'Mail' }).click();
  await page.getByLabel('Versandverbindung').selectOption({ label: 'Test-SMTP (SMTP-Server)' });
  await expect(page.getByText('Die Verbindung wurde gespeichert.')).toBeVisible();
  await page.getByLabel('Absenderadresse').fill('info@example.org');
  await page.getByLabel('Empfänger (eine Adresse pro Zeile)').fill('team@example.org');
  await page.locator('#org-subject').fill('Neue Anfrage');
  await page.locator('#org-body').fill('Von #=[vorname]=#: #=[email]=#');
  await page.getByRole('button', { name: 'Speichern' }).click();
  await expect(page.getByRole('status').filter({ hasText: /^Gespeichert\.$/ })).toBeVisible();

  // the mail section is part of the next release
  await page.getByRole('tab', { name: 'Veröffentlichen' }).click();
  await page.getByRole('button', { name: 'Versionsnummer erhöhen' }).click();
  await page.getByLabel(/Ich habe den Entwurf geprüft/).check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByText('Veröffentlicht: Version')).toBeVisible();

  // logout returns to the login page
  await page.getByRole('button', { name: 'Abmelden' }).click();
  await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
});
