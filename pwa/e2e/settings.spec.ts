import { test, expect } from '@playwright/test';
test('Einstellungen: ENV-Sperre, Revision, CSRF und Konflikt', async ({ page }) => {
  await page.route('**/admin/api/v1/**', async (route) => {
    const path = new URL(route.request().url()).pathname;
    let body: unknown = {};
    if (path.endsWith('/auth/session'))
      body = { state: 'authenticated', csrfToken: 'csrf', expiresAt: 'x' };
    else if (path.endsWith('/me')) body = { id: 'a', username: 'Test', systemAdministrator: true };
    else if (path.endsWith('/tenants')) body = { items: [] };
    else if (path.endsWith('/settings')) {
      if (route.request().method() === 'PUT') {
        expect(route.request().headers()['x-csrf-token']).toBe('csrf');
        expect(route.request().postDataJSON()).toEqual({
          revision: 'r1',
          values: { 'mcp.requestsPerMinute': '90' },
        });
        return route.fulfill({ status: 409, contentType: 'application/json', body: '{}' });
      }
      body = {
        revision: 'r1',
        items: [
          {
            definition: {
              key: 'mail.allowedNets',
              group: 'Mail-Netze',
              envName: 'FORM_MAIL_ALLOWED_NETS',
              type: 'cidrs',
              restartRequired: true,
            },
            value: '',
            source: 'env',
            locked: true,
          },
          {
            definition: {
              key: 'mcp.requestsPerMinute',
              group: 'MCP-Token-Ratelimit',
              envName: 'FORM_MCP_TOKEN_RATE_LIMIT',
              type: 'integer',
              restartRequired: false,
            },
            value: '60',
            source: 'default',
            locked: false,
          },
        ],
      };
    }
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify(body),
    });
  });
  await page.goto('/settings');
  await expect(page.getByLabel('mail.allowedNets')).toBeDisabled();
  await page.getByLabel('mcp.requestsPerMinute').fill('90');
  await page.getByRole('button', { name: 'Speichern' }).click();
  await expect(page.getByRole('alert')).toContainText('zwischenzeitlich');
  await page.getByRole('button', { name: 'Neu laden' }).click();
  await expect(page.getByLabel('mcp.requestsPerMinute')).toHaveValue('60');
});
