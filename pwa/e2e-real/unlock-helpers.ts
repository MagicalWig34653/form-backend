import { execFileSync } from 'node:child_process';
import {
  createCipheriv,
  createHash,
  generateKeyPairSync,
  pbkdf2Sync,
  randomBytes,
} from 'node:crypto';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { expect, type Page } from '@playwright/test';
import { env } from './helpers';

// Shared steps of the unlock end-to-end specs (backend/e2e-unlock.sh). The "imported" customer is built like the migration
// leaves it: a generation (public key only) and the old recovery wrap, but NO data_key_access row for the account.

export const sql = (statement: string): string =>
  execFileSync(
    'docker',
    [
      'exec',
      '-i',
      '-e',
      `MYSQL_PWD=${env('E2E_DB_PASSWORD')}`,
      env('E2E_DB_CONTAINER'),
      'mariadb',
      '-uroot',
      '-N',
      'e2e',
    ],
    { input: statement, encoding: 'utf8' },
  ).trim();

/** The admin budget is 120 requests per minute and IP; the SPA is chatty and the test fast, so the counters are cleared. */
export const resetBudget = () => sql('DELETE FROM auth_throttles');

export const uuidBin = (uuid: string) => `UNHEX('${uuid.replace(/-/g, '')}')`;

/** The old (pre-migration) key material: an X25519 pair and a recovery wrap of the private key, format of keys.ts. */
export function legacyKey(code: string) {
  const { publicKey, privateKey } = generateKeyPairSync('x25519');
  const pub = Buffer.from(String(publicKey.export({ format: 'jwk' }).x), 'base64url');
  const secret = Buffer.from(String(privateKey.export({ format: 'jwk' }).d), 'base64url');
  const kid = createHash('sha256').update(pub).digest().subarray(0, 8).toString('hex');
  const salt = randomBytes(32);
  const iv = randomBytes(12);
  const kek = pbkdf2Sync(
    Buffer.from(code.toUpperCase().replace(/[-\s]/g, '')),
    salt,
    600000,
    32,
    'sha256',
  );
  const cipher = createCipheriv('aes-256-gcm', kek, iv);
  cipher.setAAD(Buffer.from(kid));
  const wrap = Buffer.concat([cipher.update(secret), cipher.final(), cipher.getAuthTag()]);
  return { pub, secret, kid, salt, iv, wrap };
}

/** Replaces the customer's key as the import leaves it: generation + recovery wrap, no access row. */
export function importState(tenant: string, key: ReturnType<typeof legacyKey>) {
  sql(`
    DELETE FROM data_key_access WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM data_key_recovery WHERE customer_id = ${uuidBin(tenant)};
    DELETE FROM customer_key_generations WHERE customer_id = ${uuidBin(tenant)};
    INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
      VALUES (UNHEX(REPLACE(UUID(),'-','')), ${uuidBin(tenant)}, '${key.kid}', 1, UNHEX('${key.pub.toString('hex')}'), 'active', '2025-01-01 10:00:00.000000');
    INSERT INTO data_key_recovery (customer_id, kid, kdf_name, salt, iterations, iv, wrapped_key, created_at)
      VALUES (${uuidBin(tenant)}, '${key.kid}', 'pbkdf2-hmac-sha256', UNHEX('${key.salt.toString('hex')}'), 600000, UNHEX('${key.iv.toString('hex')}'), UNHEX('${key.wrap.toString('hex')}'), '2025-01-01 10:00:00.000000');
  `);
}

export const dropAccess = (tenant: string) =>
  sql(`DELETE FROM data_key_access WHERE customer_id = ${uuidBin(tenant)}`);

export async function issueCredentials(page: Page): Promise<string> {
  await page.getByRole('link', { name: 'Einbindung', exact: true }).first().click();
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  const file = await page.getByLabel('Zugangsdatei', { exact: true }).inputValue();
  const path = join(mkdtempSync(join(tmpdir(), 'e2e-unlock-')), 'credentials.json');
  writeFileSync(path, file, { mode: 0o600 });
  return path;
}

export function submit(credFile: string, key: string, marker: string): void {
  execFileSync(
    'php',
    [
      resolve(process.cwd(), '..', 'sdk', 'php', 'bin', 'submit.php'),
      '--credentials',
      credFile,
      '--url',
      env('E2E_PUBLIC_URL'),
      '--key',
      key,
      `nachricht=${marker}`,
    ],
    { encoding: 'utf8' },
  );
}

/** Opens the form's submission list and reads the first entry; the marker must appear in clear text. */
export async function expectReadable(
  page: Page,
  customer: string,
  formName: string,
  marker: string,
): Promise<void> {
  // In-app navigation only: a page load would lock the keyring (RAM only).
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${customer}` }).click();
  await page
    .getByRole('link', { name: new RegExp(formName) })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await page
    .getByRole('button', { name: /^Aktionen für Einsendung/ })
    .first()
    .click();
  await page.getByRole('menuitem', { name: 'Öffnen' }).click();
  const detail = page.getByRole('dialog');
  await expect(detail.getByText(marker)).toBeVisible();
  await detail.getByRole('button', { name: 'Schließen' }).click();
}

/** Reload = a new tab state: the keyring lives in RAM only and is locked afterwards (the cookie session survives). */
export async function reloadLocked(page: Page): Promise<void> {
  resetBudget();
  await page.reload();
  await expect(page.getByText('Schlüssel gesperrt')).toBeVisible();
}

export async function openAdvanced(page: Page): Promise<void> {
  if (!page.url().includes('/account'))
    await page.getByRole('link', { name: 'Mein Konto' }).click();
  const details = page
    .locator('details')
    .filter({ hasText: 'Erweitert: Zugriff auf Einsendungen' });
  if (!(await details.evaluate((d) => (d as HTMLDetailsElement).open)))
    await page.getByText('Erweitert: Zugriff auf Einsendungen').click();
}

export async function unlockWithPasskey(page: Page): Promise<void> {
  await openAdvanced(page);
  await page.getByRole('button', { name: 'Mit Passkey entsperren' }).first().click();
  await expect(page.getByText('Schlüssel entsperrt')).toBeVisible();
}

/** Without a PRF passkey the account key opens with the account recovery code (Konto page, "Datenzugang öffnen"). */
export async function unlockWithRecoveryCode(page: Page, code: string): Promise<void> {
  if (!page.url().includes('/account'))
    await page.getByRole('link', { name: 'Mein Konto' }).click();
  await page.getByLabel('Wiederherstellungscode', { exact: true }).fill(code);
  await page.getByRole('button', { name: 'Datenzugang öffnen' }).click();
  await expect(page.getByText('Schlüssel entsperrt')).toBeVisible();
}
