import { expect, test } from '@playwright/test';
test.beforeEach(async ({ page }) => {
  await page.route('**/admin/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = {};
    if (path.endsWith('/auth/session')) body = { state: 'authenticated', csrfToken: 'csrf' };
    else if (path.endsWith('/me')) body = { id: 'a', username: 'Test', systemAdministrator: true };
    else if (path.endsWith('/setup-state'))
      body = { required: true, migrationAllowed: true, migrationEnabled: true };
    else if (path.endsWith('/me/key-bundle'))
      body = { rpId: 'localhost', accountPublicKey: null, wraps: [], access: [], recovery: null };
    else if (path.endsWith('/settings'))
      body = { revision: 'r1', items: [{ definition: { key: 'setup.step' }, value: '0' }] };
    else if (path.endsWith('/tenants')) body = { items: [] };
    else if (path.endsWith('/migration/jobs'))
      body = {
        items: [
          {
            id: '11111111-1111-4111-8111-111111111111',
            state: 'paused',
            phase: 'anfragen',
            dryRun: false,
            error: 'interrupted',
            report: { processed: 42 },
          },
        ],
      };
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(body),
    });
  });
});
test('Erststart führt zum bestätigten Wiederherstellungsschritt', async ({ page }) => {
  await page.goto('/t');
  await expect(page).toHaveURL(/installation/);
  await expect(page.getByLabel('Einrichtungsschritte').getByRole('listitem')).toHaveCount(6);
  await page.getByRole('button', { name: 'Weiter', exact: true }).click();
  await page.getByRole('button', { name: 'Wiederherstellungscode vorbereiten' }).click();
  await expect(page.getByTestId('account-recovery-code')).toBeVisible();
  await expect(page.getByLabel('Code zur Bestätigung erneut eingeben')).toBeVisible();
});
test('Fortschritt und sicherer Fehler bleiben beim Fortsetzen am selben Lauf', async ({ page }) => {
  const id = '11111111-1111-4111-8111-111111111111';
  let resumed = false;
  await page.route(`**/migration/jobs/${id}/resume`, async (route) => {
    expect(route.request().headers()['x-csrf-token']).toBe('csrf');
    resumed = true;
    await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
  await page.goto('/migration');
  await expect(page.getByRole('heading', { name: 'Import: Pausiert' })).toBeVisible();
  await expect(page.getByRole('alert')).toContainText('interrupted');
  await page.getByRole('button', { name: 'Fortsetzen', exact: true }).click();
  await expect.poll(() => resumed).toBe(true);
});
