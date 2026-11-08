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
          const scope = page.locator('aside');
          await scope.getByRole('link', { name: label, exact: true }).first().click();
          await expect(page).toHaveURL(url);
          await expect(page.locator('#page-title')).toBeVisible();
        });
      }
    }
  });
}

// No entry is dead: in every state each one navigates and tells the user what to choose.
const needEntries = ['Formulare', 'Einsendungen', 'Statistik'] as const;

test('no customer, administrator: every form entry leads to the customer list with a hint and a create button', async ({
  page,
}) => {
  await mockApi(page, 'none');
  await page.goto('/settings');
  const aside = page.locator('aside');
  for (const name of needEntries) {
    await aside.getByRole('link', { name, exact: true }).click();
    await expect(page).toHaveURL(/\/t\?need=customer$/);
    await expect(page.getByTestId('need-hint')).toBeVisible();
    await expect(page.getByTestId('first-customer')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Kunde anlegen' }).first()).toBeVisible();
    await page.goto('/settings');
  }
  await expect(aside.locator('[aria-disabled]')).toHaveCount(0);
});

test('one customer without forms: entries open the form list, Einsendungen and Statistik explain what to pick', async ({
  page,
}) => {
  await mockApi(page, 'one-no-forms');
  await page.goto('/settings');
  const aside = page.locator('aside');
  await aside.getByRole('link', { name: 'Formulare', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}$`));
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}\\?need=entries$`));
  await expect(page.getByTestId('need-hint')).toContainText('Formular');
  await aside.getByRole('link', { name: 'Statistik', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}\\?need=statistics$`));
  await expect(page.getByTestId('need-hint')).toBeVisible();
});

test('customer with a form: Einsendungen and Statistik open the last form after leaving it', async ({
  page,
}) => {
  await mockApi(page, 'one-with-forms');
  await page.goto('/t');
  const aside = page.locator('aside');
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}\\?need=entries$`));
  await page.goto(`/t/${T}/f/${F}`);
  await aside.getByRole('link', { name: 'Kunden', exact: true }).click();
  await aside.getByRole('link', { name: 'Einsendungen', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}/entries$`));
  await aside.getByRole('link', { name: 'Kunden', exact: true }).click();
  await aside.getByRole('link', { name: 'Statistik', exact: true }).click();
  await expect(page).toHaveURL(new RegExp(`/t/${T}/f/${F}#statistics$`));
});

test('several customers and none chosen: entries lead to the customer list with a hint', async ({
  page,
}) => {
  await mockApi(page, 'two');
  await page.goto('/settings');
  const aside = page.locator('aside');
  await aside.getByRole('link', { name: 'Formulare', exact: true }).click();
  await expect(page).toHaveURL(/\/t\?need=customer$/);
  await expect(page.getByTestId('need-hint')).toBeVisible();
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
  await page.getByRole('dialog').getByRole('combobox').fill('Statistik');
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL(new RegExp(`/t/${T}\\?need=statistics$`));
  await expect(page.getByTestId('need-hint')).toBeVisible();
});
