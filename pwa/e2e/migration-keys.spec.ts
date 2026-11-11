import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';

// ADR 0040: the plan is filled from the source check; only the customer name is typed.
const form = '11111111-1111-4111-8111-111111111111';
const form2 = '66666666-6666-4666-8666-666666666666';
const connection = '44444444-4444-4444-8444-444444444444';
const active = 'aaaaaaaaaaaaaaaa';
const retiring = 'bbbbbbbbbbbbbbbb';
const other = 'cccccccccccccccc';
const missing = '9999999999999999';
const inventory = (withMissing: boolean) => ({
  schemaHMAC: 'c'.repeat(64),
  readOnly: true,
  formIds: [form, form2],
  connectionIds: [connection],
  counts: { anfragen: 9, datenschluessel: 3 },
  forms: [
    { id: form, name: 'Kontaktformular', connectionIds: [connection] },
    { id: form2, name: null, connectionIds: [] },
  ],
  connections: [{ id: connection, kind: 'smtp', name: 'Versand Alt' }],
  keys: [
    { kid: active, status: 'aktiv', createdAt: 1700000000, publicKeyValid: true },
    { kid: retiring, status: 'auslaufend', createdAt: 1600000000, publicKeyValid: true },
    { kid: other, status: 'andere', createdAt: 1500000000, publicKeyValid: true },
  ],
  keysComplete: true,
  invalidKeys: 0,
  keyUsage: {
    complete: true,
    scannedSubmissions: 9,
    items: [
      { kid: active, submissions: 6, inKeyStore: true, formIds: [form], formIdsComplete: true },
      ...(withMissing
        ? [
            {
              kid: missing,
              submissions: 2,
              inKeyStore: false,
              formIds: [form2],
              formIdsComplete: true,
            },
          ]
        : []),
    ],
  },
});

async function mock(page: Page, withMissing: boolean) {
  const jobs: unknown[] = [];
  await page.route('**/admin/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = {};
    if (path.endsWith('/auth/session')) body = { state: 'authenticated', csrfToken: 'csrf' };
    else if (path.endsWith('/me')) body = { id: 'a', username: 'Test', systemAdministrator: true };
    else if (path.endsWith('/setup-state'))
      body = { required: false, migrationAllowed: true, migrationEnabled: true };
    else if (path.endsWith('/me/key-bundle'))
      body = { rpId: 'localhost', accountPublicKey: null, wraps: [], access: [], recovery: null };
    else if (path.endsWith('/tenants')) body = { items: [] };
    else if (path.endsWith('/migration/test')) body = inventory(withMissing);
    else if (path.endsWith('/migration/jobs') && route.request().method() === 'POST') {
      jobs.push(route.request().postDataJSON());
      body = { id: '77777777-7777-4777-8777-777777777777' };
    } else if (path.endsWith('/migration/jobs')) body = { items: [] };
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(body),
    });
  });
  return jobs;
}

async function toMapping(page: Page) {
  await page.goto('/migration');
  await page.getByLabel('Host').fill('db.example');
  await page.getByLabel('Datenbank').fill('alt');
  await page.getByLabel('Benutzer').fill('lesen');
  await page.getByRole('button', { name: 'Verbindung prüfen' }).click();
  await expect(page.getByText('Prüfbericht der Quelle')).toBeVisible();
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
}

test('Schlüssel, Formulare und Verbindungen werden automatisch in den Plan übernommen', async ({
  page,
}) => {
  const jobs = await mock(page, false);
  await toMapping(page);
  const keys = page.getByTestId('migration-keys');
  await expect(keys.getByText(active)).toBeVisible();
  await expect(keys.getByText(retiring)).toBeVisible();
  await expect(keys.getByText('6 Einsendungen')).toBeVisible();
  await expect(keys.getByText('Generation 2')).toBeVisible();
  await expect(keys.getByText(/Wird nicht übernommen/)).toBeVisible();
  await expect(page.getByTestId('migration-key-warning')).toHaveCount(0);
  await expect(page.getByTestId('migration-forms')).toContainText('Kontaktformular');
  await expect(page.getByTestId('migration-forms')).toContainText('Ohne Namen');
  const start = page.getByRole('button', { name: 'Prüflauf starten' });
  await expect(start).toBeDisabled();
  await page.getByLabel('Kundenname', { exact: false }).fill('Synthetischer Kunde');
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await start.click();
  await expect.poll(() => jobs.length).toBe(1);
  const sent = jobs[0] as {
    plan: {
      namespace: string;
      customers: Record<string, string>;
      formCustomers: Record<string, string>;
      connectionCustomers: Record<string, string[]>;
      keyCustomers: Record<string, string>;
      keyGenerationNumbers: Record<string, number>;
    };
    expectedSchema: string;
  };
  const [customer] = Object.keys(sent.plan.customers);
  expect(sent.plan.customers[customer!]).toBe('Synthetischer Kunde');
  expect(sent.plan.namespace).toBe('legacy-alt');
  expect(sent.expectedSchema).toBe('c'.repeat(64));
  expect(sent.plan.formCustomers).toEqual({ [form]: customer, [form2]: customer });
  expect(sent.plan.connectionCustomers).toEqual({ [connection]: [customer] });
  expect(sent.plan.keyCustomers).toEqual({ [active]: customer, [retiring]: customer });
  expect(sent.plan.keyGenerationNumbers).toEqual({ [retiring]: 1, [active]: 2 });
});

test('fehlender Schlüssel wird vor dem Start deutlich gewarnt; 320 px ohne axe-Verstöße', async ({
  page,
}) => {
  await page.setViewportSize({ width: 320, height: 900 });
  await mock(page, true);
  await toMapping(page);
  const warning = page.getByTestId('migration-key-warning');
  await expect(warning).toContainText('2 Einsendungen verwenden einen Schlüssel');
  await expect(warning).toContainText(missing);
  const width = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(width).toBeLessThanOrEqual(320);
  const results = await new AxeBuilder({ page }).analyze();
  expect(results.violations).toEqual([]);
});
