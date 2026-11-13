import { test, expect } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey, toOverview } from './helpers';
import { resetBudget, source, target } from './migration-helpers';

// QA finding 7B5E1E8A: the DOCUMENTED path of docs/UMSTIEG-CHECKLISTE.md section 2 "new customer" (customer name only), end to end in the
// browser against the REAL binary, real target and legacy MariaDB (synthetic dump), NO shortcut: no customer created beforehand, no
// "choose existing customer", no SQL that dismantles keys or sets states. Orchestrated by backend/e2e-migration-newcustomer.sh.
// Chain: passkey -> Umstieg -> source check -> mapping NEW customer (name) -> dry run -> import -> probe -> release imported submissions
// -> account, Advanced: the field #legacy-key-<customer> must exist -> adopt the old key -> list -> open a submission -> fields readable.

const CUSTOMER = 'Neukunde Umstieg GmbH';
const SYNTHETIC_ACTIVE_KEY = 'ERERERERERERERERERERERERERERERERERERERERERE'; // seed 0x11 of RehearsalSource (base64url)

test('migration to a NEW customer: adopt the old key without SQL, submission readable', async ({
  page,
  context,
}) => {
  test.setTimeout(480_000);
  page.on('pageerror', (e) => console.log('PAGEERROR', e.message));
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await toOverview(page);
  expect(target('SELECT COUNT(*) FROM customers')).toBe('0');
  resetBudget();

  // 1. source check, mapping with a NEW customer name only
  await page.getByRole('link', { name: 'Umstieg', exact: true }).first().click();
  await expect(page.getByRole('heading', { name: 'Umstieg', exact: true })).toBeVisible();
  await page.getByLabel('Host', { exact: true }).fill('127.0.0.1');
  await page.getByLabel('Port', { exact: true }).fill(env('E2E_LEGACY_PORT'));
  await page.getByLabel('Datenbank', { exact: true }).fill(env('E2E_LEGACY_DB'));
  await page.getByLabel('Benutzer', { exact: true }).fill(env('E2E_LEGACY_USER'));
  await page.getByLabel('Passwort', { exact: true }).fill(env('E2E_LEGACY_PASSWORD'));
  await page.getByLabel('TLS-Modus').selectOption('disable');
  await page.getByRole('button', { name: 'Verbindung prüfen' }).click();
  await expect(page.getByText(/Nur lesender Zugang geprüft/)).toBeVisible();
  await page.getByRole('button', { name: 'Weiter' }).click();
  await expect(page.getByRole('heading', { name: 'Zuordnung', exact: true })).toBeVisible();
  await page.getByLabel('Kundenname').fill(CUSTOMER);
  await expect(page.getByTestId('migration-summary')).toContainText('Der Plan ist vollständig.');
  await page.getByRole('button', { name: 'Prüflauf starten' }).click();
  await expect(page.getByText('Der Prüflauf ist abgeschlossen.')).toBeVisible({ timeout: 180_000 });
  expect(target('SELECT COUNT(*) FROM submissions')).toBe('0');

  // 2. import
  await page.getByRole('button', { name: 'Import starten' }).click();
  await expect(page.getByRole('heading', { name: 'Prüfbericht', exact: true })).toBeVisible({
    timeout: 240_000,
  });
  expect(target('SELECT COUNT(*) FROM submissions')).toBe(source('SELECT COUNT(*) FROM anfragen'));
  expect(target(`SELECT state FROM customers WHERE name='${CUSTOMER}'`)).toBe('active');
  const hex = target(`SELECT LOWER(HEX(id)) FROM customers WHERE name='${CUSTOMER}'`);
  const tenant = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  // the importing administrator holds no key access yet (the old key must come from the browser)
  expect(target('SELECT COUNT(*) FROM data_key_access')).toBe('0');
  console.log('MEMBERSHIPS after import:', target('SELECT COUNT(*) FROM customer_memberships'));

  // 3. probe with the synthetic old key, then release
  resetBudget();
  await expect(page.getByRole('heading', { name: 'Prüfung', exact: true }).first()).toBeVisible();
  const probeResponse = page.waitForResponse((r) =>
    /\/migration\/jobs\/[^/]+\/probe$/.test(r.url()),
  );
  await page.getByRole('button', { name: 'Entschlüsselungsprobe laden' }).click();
  const sampleKid = ((await (await probeResponse).json()) as { wire: string }).wire.split('|')[1];
  const probeKey = { a6077815bba8b14c: 0x10, d19bf3f082782c87: 0x11 }[sampleKid];
  expect(probeKey, `sample key id ${sampleKid} is a synthetic old key`).toBeTruthy();
  await page
    .getByLabel('Privater Altschlüssel')
    .fill(Buffer.alloc(32, probeKey).toString('base64url'));
  await page.getByRole('button', { name: 'Probe lokal entschlüsseln' }).click();
  await page.getByRole('alertdialog').getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText(/Lokale Entschlüsselung bestätigt/)).toBeVisible();
  await page.getByRole('button', { name: 'Importierte Einsendungen freigeben' }).click();
  await expect(page.getByTestId('migration-released')).toBeVisible();
  expect(Number(target("SELECT COUNT(*) FROM submissions WHERE state='accepted'"))).toBeGreaterThan(
    0,
  );

  // 4. account, Advanced: the old key of the NEW customer is adoptable (no SQL, no existing customer)
  await page.getByRole('button', { name: 'Zur Übernahme im Konto' }).click();
  await expect(page).toHaveURL(/\/account\?legacy=1/);
  const field = page.locator(`#legacy-key-${tenant}`);
  await expect(field).toBeVisible({ timeout: 30_000 });
  await field.fill(SYNTHETIC_ACTIVE_KEY);
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).first().click();
  await expect(page.getByText(/Zugang für die importierte Generation .* angelegt/)).toBeVisible();
  expect(target(`SELECT COUNT(*) FROM data_key_access WHERE customer_id=UNHEX('${hex}')`)).not.toBe(
    '0',
  );

  // 5. list and detail: fields readable
  await page.getByRole('link', { name: 'Kunden', exact: true }).first().click();
  await page.getByRole('link', { name: `Öffnen: ${CUSTOMER}` }).click();
  await page
    .getByRole('link', { name: /Kontaktformular Müller/ })
    .first()
    .click();
  await page.getByRole('link', { name: 'Einsendungen', exact: true }).last().click();
  await expect(page.getByText('Noch keine Einsendungen')).toHaveCount(0);
  await page
    .getByRole('button', { name: /^Aktionen für Einsendung/ })
    .first()
    .click();
  await page.getByRole('menuitem', { name: 'Öffnen' }).click();
  const detail = page.getByRole('dialog', { name: 'Einsendungsdetail' });
  await expect(detail.getByRole('heading', { name: 'Felder' })).toBeVisible();
  await expect(detail.getByText(/konnte nicht|passt nicht|Schlüssel/)).toHaveCount(0);
  const marker = (await detail.getByText(/KLARTEXT-MARKER-\d+/).innerText()).trim();
  const n = marker.replace('KLARTEXT-MARKER-', '');
  await expect(
    detail.locator('dt', { hasText: /^Name$/ }).locator('xpath=following-sibling::dd[1]'),
  ).toHaveText(`Jörg Müßig ${n}`);
});
