import { test } from '@playwright/test';
const out = process.env.SHOTS;
const j = (b: unknown, s = 200) => ({
  status: s,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
test.skip(!out, 'set SHOTS');
for (const scheme of ['light', 'dark'] as const)
  test(`auth ${scheme}`, async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
    let state = 'passkey';
    await page.route('**/admin/api/v1/**', (r) => {
      const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
      if (p === '/auth/session')
        return r.fulfill(
          j({ state, csrfToken: 'c', subjectId: 'a', expiresAt: 'x', totpAllowed: false }),
        );
      if (p === '/me')
        return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
      if (p === '/setup-state') return r.fulfill(j({ required: true }));
      if (p.includes('key-bundle') || p.includes('keys/bundle') || p.includes('bundle'))
        return r.fulfill(j({ rpId: 'x.example.org', recovery: null, accountPublicKey: null }));
      return r.fulfill(j({ items: [] }));
    });
    const name = scheme === 'light' ? 'hell' : 'dunkel';
    await page.goto('/login');
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: `${out}/login-${name}.png`, fullPage: true });
    state = 'authenticated';
    await page.goto('/login');
    await page.waitForTimeout(1500);
    await page.screenshot({ path: `${out}/login-recovery-${name}.png`, fullPage: true });
    await page.goto('/installation');
    await page.waitForTimeout(1500);
    await page.screenshot({ path: `${out}/installation-${name}.png`, fullPage: true });
  });
