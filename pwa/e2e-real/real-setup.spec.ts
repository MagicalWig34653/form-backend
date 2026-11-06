import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test, expect } from '@playwright/test';
import {
  addAuthenticator,
  configureAndPublish,
  createCustomer,
  createForm,
  env,
  loginAndSecure,
  registerPasskey,
  toOverview,
} from './helpers';

// First administrator from the operator command: enrollment link -> real passkey registration (CDP virtual authenticator)
// -> passkey login -> password. Orchestrated by backend/e2e-setup.sh (it runs `bootstrap-admin` and passes the link).
test('bootstrap link registers a passkey and the same passkey logs in', async ({
  page,
  context,
}) => {
  await addAuthenticator(page, context);

  await registerPasskey(page, env('E2E_SETUP_LINK'));

  // the link is single use (leave the page first: a hash-only navigation would not reload the app)
  await page.goto('about:blank');
  await page.goto(env('E2E_SETUP_LINK'));
  await page.getByRole('button', { name: 'Passkey erstellen' }).click();
  await expect(page.getByRole('alert')).toContainText('fehlgeschlagen');

  await loginAndSecure(page);

  // Customer, form and fields through the real UI with the keyring unlocked by the PRF passkey.
  await toOverview(page);
  await createCustomer(page, 'E2E Kunde');
  await createForm(page, 'Kontakt');
  await configureAndPublish(page, [
    ['email', 'E-Mail', 'email'],
    ['vorname', 'Vorname', 'text'],
  ]);
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Einrichtungsdatei ausstellen' }).click();
  const file = await page.getByLabel('Einrichtungsdatei', { exact: true }).inputValue();
  const creds = JSON.parse(file) as Record<string, string>;
  expect(creds.signingSeed).toMatch(/^[A-Za-z0-9_-]{43}$/);
  const dir = mkdtempSync(join(tmpdir(), 'e2e-sdk-'));
  const credFile = join(dir, 'credentials.json');
  writeFileSync(credFile, file, { mode: 0o600 });

  // A real PHP SDK submission through the public listener; the marker must only be readable in the browser afterwards.
  const marker = 'E2E-MARKER-' + Math.random().toString(36).slice(2, 8);
  const sdk = resolve(process.cwd(), '..', 'sdk', 'php', 'bin', 'submit.php');
  const out = execFileSync(
    'php',
    [
      sdk,
      '--credentials',
      credFile,
      '--url',
      process.env.E2E_PUBLIC_URL!,
      '--key',
      'e2e-1',
      `nachricht=${marker}`,
      'email=a@example.org',
      'vorname=Erika',
    ],
    { encoding: 'utf8' },
  );
  console.log('SDK:', out.trim().slice(0, 200));

  await page.getByRole('link', { name: 'Einsendungen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Öffnen', exact: true }).click();
  const detail = page.getByRole('dialog');
  await expect(detail.getByText(marker)).toBeVisible();
  await expect(detail.getByText('Erika')).toBeVisible();
  await detail.getByRole('button', { name: 'Schließen' }).click();

  const entriesUrl = new URL(page.url()).pathname
    .replace(/^\/t\//, '/admin/api/v1/tenants/')
    .replace('/f/', '/forms/');
  const entryCount = async () =>
    page.evaluate(async (u) => {
      const r = await fetch(u, { credentials: 'include' });
      return ((await r.json()) as { items: unknown[] }).items.length;
    }, entriesUrl);
  // The same submission replayed with the same key is accepted idempotently (still one entry).
  execFileSync(
    'php',
    [
      sdk,
      '--credentials',
      credFile,
      '--url',
      process.env.E2E_PUBLIC_URL!,
      '--key',
      'e2e-1',
      `nachricht=${marker}`,
      'email=a@example.org',
      'vorname=Erika',
    ],
    { encoding: 'utf8' },
  );
  await expect.poll(entryCount).toBe(1);

  // Server-side validation: an unknown field is rejected with 422 and never stored.
  let rejected = false;
  try {
    execFileSync(
      'php',
      [
        sdk,
        '--credentials',
        credFile,
        '--url',
        process.env.E2E_PUBLIC_URL!,
        '--key',
        'e2e-2',
        'nachricht=x',
        'unbekannt=y',
      ],
      { encoding: 'utf8', stdio: 'pipe' },
    );
  } catch {
    rejected = true;
  }
  expect(rejected).toBe(true);
  await expect.poll(entryCount).toBe(1);

  await page.getByRole('button', { name: 'Abmelden' }).click();
  // The login page must show the signed-out state right away (no stale "Sie sind angemeldet"), and the server session is gone.
  await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
  expect(
    await page.evaluate(
      async () => (await fetch('/admin/api/v1/me', { credentials: 'include' })).status,
    ),
  ).toBe(401);
});
