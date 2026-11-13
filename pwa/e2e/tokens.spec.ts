import { test, expect } from '@playwright/test';

test('API-Tokens anlegen, einmalig anzeigen und widerrufen', async ({ page }) => {
  let created = false;
  let revoked = false;
  await page.route('**/admin/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = {};
    if (path.endsWith('/auth/session'))
      body = { state: 'authenticated', csrfToken: 'csrf', expiresAt: 'x' };
    else if (path.endsWith('/me')) body = { id: 'a', username: 'Test', systemAdministrator: false };
    else if (path.endsWith('/tenants')) body = { items: [] };
    else if (path.endsWith('/account/tokens') && route.request().method() === 'POST') {
      expect(route.request().headers()['x-csrf-token']).toBe('csrf');
      created = true;
      body = { id: 'token-id', token: 'kfm_synthetic_browser_fixture' };
    } else if (path.endsWith('/tokens/token-id')) {
      revoked = true;
      return route.fulfill({ status: 204 });
    } else if (path.endsWith('/account/tokens'))
      body = {
        items: created
          ? [
              {
                id: 'token-id',
                label: 'Browser-Test',
                expires_at: 0,
                last_used_at: null,
                revoked_at: revoked ? 0 : null,
                scopes_json: '["konfiguration.lesen"]',
                scope_json: '{}',
              },
            ]
          : [],
      };
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(body),
    });
  });
  await page.goto('/api-tokens');
  await page.getByRole('button', { name: 'Token anlegen' }).click();
  await page.getByLabel('Bezeichnung').fill('Browser-Test');
  await page.getByLabel('Kunden-ID (UUID)').fill('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  await page.getByRole('dialog').getByRole('button', { name: 'Token anlegen' }).click();
  await expect(page.getByText('kfm_synthetic_browser_fixture')).toBeVisible();
  await page.getByRole('button', { name: 'Ausblenden' }).click();
  await expect(page.getByText('kfm_synthetic_browser_fixture')).toHaveCount(0);
  await page.reload();
  await expect(page.getByText('kfm_synthetic_browser_fixture')).toHaveCount(0);
  await page.getByRole('button', { name: 'Widerrufen' }).click();
  await expect(page.getByText('Widerrufen', { exact: true })).toBeVisible();
});
