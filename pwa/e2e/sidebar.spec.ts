import { test, expect, type Page } from '@playwright/test';

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';

async function mockApi(page: Page, tenants = true) {
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants' && !tenants) return r.fulfill(j({ items: [] }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            {
              id: T,
              name: 'Kunde A',
              permissions: [
                'form.read',
                'draft.write',
                'release.publish',
                'key.manage',
                'identity.manage',
              ],
            },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: null }],
          nextCursor: null,
        }),
      );
    if (p.endsWith('/members')) return r.fulfill(j({ items: [], assignable: [] }));
    return r.fulfill(j({ items: [] }));
  });
}

// Every sidebar entry must lead to its route and show its page heading, from several start pages and both layouts.
const entries: [string, RegExp][] = [
  ['Kunden', /\/t$/],
  ['Formulare', new RegExp(`/t/${T}$`)],
  ['Tokens / MCP', /\/api-tokens$/],
  ['Einstellungen', /\/settings$/],
  ['Einrichtung', /\/installation$/],
  ['Umstieg', /\/migration$/],
  ['Mitglieder', new RegExp(`/t/${T}/members$`)],
  ['Verbindungen', /\/connections$/],
  ['Mein Konto', /\/account$/],
];
const starts = [`/t/${T}`, '/t', `/t/${T}/f/${F}`, '/settings'];

for (const [name, viewport] of [
  ['desktop', { width: 1280, height: 800 }],
  ['mobile', { width: 390, height: 800 }],
] as const) {
  test.describe(`sidebar navigation (${name})`, () => {
    test.use({ viewport });
    for (const start of name === 'mobile' ? starts.slice(0, 1) : starts) {
      for (const [label, url] of entries) {
        test(`${start}: click "${label}"`, async ({ page }) => {
          await mockApi(page);
          await page.goto(start);
          if (name === 'mobile')
            await page.getByRole('button', { name: 'Navigation öffnen' }).click();
          const scope = name === 'mobile' ? page.getByRole('dialog') : page.locator('aside');
          await scope.getByRole('link', { name: label, exact: true }).first().click();
          await expect(page).toHaveURL(url);
          await expect(page.locator('#page-title')).toBeVisible();
        });
      }
    }
  });
}

test('without a customer the form entries are inactive instead of linking to the same page', async ({
  page,
}) => {
  await mockApi(page, false);
  await page.goto('/t');
  const aside = page.locator('aside');
  for (const name of ['Formulare', 'Einsendungen', 'Statistik'])
    await expect(aside.getByText(name, { exact: true })).toHaveAttribute('aria-disabled', 'true');
  await expect(aside.getByRole('link', { name: 'Einsendungen' })).toHaveCount(0);
  await expect(aside.getByRole('link', { name: 'Kunden', exact: true })).toBeVisible();
});

test('Einsendungen and Statistik reopen the last form after leaving it', async ({ page }) => {
  await mockApi(page);
  await page.goto('/t');
  const aside = page.locator('aside');
  await expect(aside.getByText('Einsendungen', { exact: true })).toHaveAttribute(
    'aria-disabled',
    'true',
  );
  await page.goto(`/t/${T}/f/${F}`);
  await aside.getByRole('link', { name: 'Kunden', exact: true }).click();
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}/entries$`));
});
