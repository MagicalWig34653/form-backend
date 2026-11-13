import { test, expect, type Page } from '@playwright/test';

// Display preferences live in the account: loaded after sign-in, written after changes. API answers are synthetic.
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const j = (b: unknown, status = 200) => ({
  status,
  contentType: 'application/json',
  body: JSON.stringify(b),
});

async function mock(page: Page, stored: Record<string, unknown>, putStatus = 200) {
  const puts: unknown[] = [];
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
    if (p === '/me/preferences') {
      if (r.request().method() === 'GET') return r.fulfill(j(stored));
      const body = r.request().postDataJSON() as Record<string, unknown>;
      puts.push(body);
      if (putStatus !== 200)
        return r.fulfill(j({ code: 'internal', message: 'Fehler' }, putStatus));
      Object.assign(stored, body);
      return r.fulfill(j(stored));
    }
    return r.fulfill(j({ items: [] }));
  });
  return puts;
}

async function openMenu(page: Page) {
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
}

test('account values are applied after sign-in and win over the browser cache', async ({
  page,
}) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.addInitScript(() => {
    if (!sessionStorage.getItem('seeded')) {
      localStorage.setItem('theme', 'light');
      localStorage.setItem('accent', 'gelb');
      localStorage.setItem('appearance-account', 'a');
      sessionStorage.setItem('seeded', '1');
    }
  });
  const puts = await mock(page, { theme: 'dark', accent: 'violett', glow: 2 });
  await page.goto(`/t/${T}`);
  const root = page.locator('html');
  await expect(root).toHaveClass(/dark/);
  await expect(root).toHaveAttribute('data-accent', 'violett');
  await expect(root).toHaveAttribute('data-glow-step', '2');
  // The cache now holds the account values for the next first paint.
  expect(await page.evaluate(() => localStorage.getItem('accent'))).toBe('violett');
  expect(puts).toEqual([]);
  await openMenu(page);
  await expect(page.getByTestId('appearance-storage')).toHaveText(
    'Wird in Ihrem Konto gespeichert.',
  );
});

test('a change in the menu is written to the account with the full state', async ({ page }) => {
  const puts = await mock(page, { theme: 'dark', accent: 'violett', glow: 0 });
  await page.goto(`/t/${T}`);
  await expect(page.locator('html')).toHaveAttribute('data-accent', 'violett');
  await openMenu(page);
  await page.getByRole('button', { name: 'Grün', exact: true }).click();
  await expect(page.locator('html')).toHaveAttribute('data-accent', 'gruen');
  await page.getByRole('button', { name: 'Hell', exact: true }).click();
  await expect.poll(() => puts.length).toBe(1);
  expect(puts[0]).toEqual({ theme: 'light', accent: 'gruen', glow: 0 });
  await expect(page.getByTestId('appearance-save-failed')).toHaveCount(0);
});

test('a failed save shows a hint and keeps the choice', async ({ page }) => {
  const puts = await mock(page, { theme: 'light', accent: 'tuerkis', glow: 0 }, 500);
  await page.goto(`/t/${T}`);
  await expect(page.locator('html')).toHaveAttribute('data-accent', 'tuerkis');
  await openMenu(page);
  await page.getByRole('button', { name: 'Rot', exact: true }).click();
  await expect.poll(() => puts.length).toBe(1);
  await expect(page.getByTestId('appearance-save-failed')).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('data-accent', 'rot');
  expect(await page.evaluate(() => localStorage.getItem('appearance-dirty'))).toBe('a');
});
