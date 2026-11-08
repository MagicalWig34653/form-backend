import { test } from '@playwright/test';

// SHOTS=dir npx playwright test e2e/shots-appearance.spec.ts: Darstellung-Dialog und Leuchten (skipped otherwise).
const out = process.env.SHOTS;
test.skip(!out, 'set SHOTS');
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const j = (b: unknown) => ({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify(b),
});

test('appearance dialog and glow', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await page.addInitScript(() => {
    localStorage.setItem('accent', 'violett');
    localStorage.setItem('glow', '4');
  });
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(j({ items: [{ id: T, name: 'Kunde A', permissions: ['form.read'] }] }));
    return r.fulfill(j({ items: [] }));
  });
  await page.goto(`/t/${T}`);
  await page.waitForLoadState('networkidle');
  await page.screenshot({ path: `${out}/glow-violett-dunkel-desktop.png` });
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  await page.waitForTimeout(300);
  await page.screenshot({ path: `${out}/darstellung-dialog-dunkel-desktop.png` });
});
