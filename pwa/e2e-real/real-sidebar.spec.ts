import { test, expect } from '@playwright/test';
import { addAuthenticator, env, loginAndSecure, registerPasskey } from './helpers';

// Real backend, first administrator right after the first passkey login and recovery code: every sidebar entry must
// navigate (the setup assistant is still open). Orchestrated like backend/e2e-setup.sh.
test('sidebar entries navigate right after the first login', async ({ page, context }) => {
  await addAuthenticator(page, context);
  await registerPasskey(page, env('E2E_SETUP_LINK'));
  await loginAndSecure(page);
  await page.screenshot({ path: 'test-results/after-login.png' });
  console.log('URL after login:', page.url());
  const aside = page.locator('aside');
  for (const [name, path] of [
    ['Kunden', '/t'],
    ['Tokens / MCP', '/api-tokens'],
    ['Einstellungen', '/settings'],
    ['Umstieg', '/migration'],
    ['Einrichtung', '/installation'],
    ['Mein Konto', '/account'],
    ['Kunden', '/t'],
  ] as const) {
    await aside.getByRole('link', { name, exact: true }).first().click();
    await page.waitForTimeout(500);
    console.log(name, '->', page.url());
    await expect(page, name).toHaveURL(new RegExp(`${path}$`));
    await expect(page.locator('#page-title'), name).toBeVisible();
  }
});
