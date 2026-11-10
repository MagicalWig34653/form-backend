import { test, expect, type Page } from '@playwright/test';

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';

type State = 'none' | 'one-no-forms' | 'one-with-forms' | 'two';
async function mockApi(page: Page, tenants: boolean | State = true) {
  const state: State = tenants === false ? 'none' : tenants === true ? 'one-with-forms' : tenants;
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
    if (p === '/tenants' && state === 'none') return r.fulfill(j({ items: [] }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            ...(state === 'two'
              ? [{ id: 'bbbbbbbb-1111-4111-8111-11111111111b', name: 'Kunde B', permissions: [] }]
              : []),
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
          items:
            state === 'one-no-forms'
              ? []
              : [{ id: F, name: 'Kontakt', active: true, currentReleaseId: null }],
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
          const scope = page.locator('aside');
          await scope.getByRole('link', { name: label, exact: true }).first().click();
          await expect(page).toHaveURL(url);
          await expect(page.locator('#page-title')).toBeVisible();
        });
      }
    }
  });
}

// Einsendungen and Statistik follow the area (customer/form chosen in the area menu); nothing is dead.
test('overall area: Einsendungen and Statistik stay on the overall dashboard, no form entry', async ({
  page,
}) => {
  await mockApi(page, 'none');
  await page.goto('/settings');
  const aside = page.locator('aside');
  await expect(aside.getByRole('link', { name: 'Formulare', exact: true })).toHaveCount(0);
  for (const [name, hash] of [
    ['Einsendungen', 'recent-entries'],
    ['Statistik', 'statistics'],
  ] as const) {
    await aside.getByRole('link', { name, exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`/overview#${hash}$`));
    await expect(page.getByRole('heading', { name: 'Gesamtübersicht' })).toBeVisible();
    await page.goto('/settings');
  }
  await expect(aside.locator('[aria-disabled]')).toHaveCount(0);
  await aside.getByRole('link', { name: 'Dashboard', exact: true }).click();
  await expect(page).toHaveURL(/\/overview$/);
  await aside.getByRole('link', { name: 'Kunden', exact: true }).click();
  await expect(page).toHaveURL(/\/t$/);
  await expect(page.getByTestId('first-customer')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Kunde anlegen' }).first()).toBeVisible();
});

test('customer area: Formulare, Einsendungen and Statistik lead to the customer overview', async ({
  page,
}) => {
  await mockApi(page, 'one-no-forms');
  await page.goto(`/t/${T}/members`);
  const aside = page.locator('aside');
  await aside.getByRole('link', { name: 'Formulare', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}$`));
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}#recent-entries$`));
  await aside.getByRole('link', { name: 'Statistik', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}#statistics$`));
});

test('form area: Formulare leads back to the customer, Einsendungen and Statistik stay in the form', async ({
  page,
}) => {
  await mockApi(page, 'one-with-forms');
  await page.goto(`/t/${T}/f/${F}`);
  const aside = page.locator('aside');
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}/entries$`));
  await aside.getByRole('link', { name: 'Statistik', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}#statistics$`));
  // Leaving the form does not keep it as the area: the overall menu entries follow the route.
  await aside.getByRole('link', { name: 'Kunden', exact: true }).click();
  await expect(aside.getByRole('link', { name: 'Einsendungen', exact: true })).toHaveAttribute(
    'href',
    '/overview#recent-entries',
  );
});

test('breadcrumb links and the command palette also lead somewhere', async ({ page }) => {
  await mockApi(page, 'one-with-forms');
  await page.goto(`/t/${T}/f/${F}/entries`);
  await page
    .getByRole('navigation', { name: 'Brotkrumen' })
    .getByRole('link', { name: 'Formulare' })
    .click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}$`));
  await page.goto('/settings');
  await expect(page.locator('aside')).toBeVisible();
  await page
    .getByRole('button', { name: /Suchen/ })
    .first()
    .click();
  await page.getByRole('dialog').getByRole('combobox').fill('Gesamt');
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL('/overview');
});
