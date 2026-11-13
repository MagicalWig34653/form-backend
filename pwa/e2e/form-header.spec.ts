import { expect, test, type Page } from '@playwright/test';

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';
const D = '33333333-3333-4333-8333-333333333333';
const j = (b: unknown) => ({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
async function mock(page: Page) {
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            {
              id: T,
              name: 'Kunde A',
              permissions: ['form.read', 'draft.write', 'release.publish', 'key.manage'],
            },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms/${F}`)
      return r.fulfill(
        j({
          id: F,
          name: 'Kontakt',
          active: true,
          currentReleaseId: D,
          currentReleaseVersion: 1,
          draftIds: [D],
          mailConnectionId: null,
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: D }],
          nextCursor: null,
        }),
      );
    return r.fulfill(j({ items: [] }));
  });
}

for (const width of [320, 390]) {
  test(`mobiler Formularkopf bei ${width} px: kompakt, ohne Seitenscrollen, Reiter mit Hinweis`, async ({
    page,
  }) => {
    await page.setViewportSize({ width, height: 800 });
    await mock(page);
    await page.goto(`/t/${T}/f/${F}/entries`);
    await expect(page.getByRole('heading', { level: 1, name: 'Kontakt' })).toBeVisible();
    // Chips sit on one line.
    const chips = page.locator('header [data-slot="status-chip"], header span.inline-flex');
    const tops = await chips.evaluateAll((els) =>
      els
        .filter((el) => (el as HTMLElement).offsetParent !== null)
        .map((el) => Math.round(el.getBoundingClientRect().top)),
    );
    expect(new Set(tops).size).toBeLessThanOrEqual(2);
    // Both actions share one row and keep their full accessible names.
    const edit = page.getByRole('link', { name: 'Entwurf bearbeiten' });
    const publish = page.getByRole('link', { name: 'Prüfen & veröffentlichen' });
    const [a, b] = [await edit.boundingBox(), await publish.boundingBox()];
    expect(Math.abs((a?.y ?? 0) - (b?.y ?? 99))).toBeLessThan(4);
    // The tab bar says that more tabs follow.
    await expect(page.locator('nav [data-more="right"]')).toBeVisible();
    // The header leaves room for content: tabs end above 300 px.
    const tabs = await page
      .getByRole('navigation', { name: 'Bereiche des Formulars' })
      .boundingBox();
    expect((tabs?.y ?? 999) + (tabs?.height ?? 0)).toBeLessThan(330);
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });
}
