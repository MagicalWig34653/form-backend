import { test } from '@playwright/test';
const out = process.env.SHOTS;
const j = (b: unknown) => ({
  status: 200,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
test.skip(!out, 'set SHOTS');
const groups = ['Missbrauchsschutz', 'Mail-Netze', 'Limits', 'Hosts', 'Webhook-Limits'];
const items = groups.flatMap((g, gi) =>
  [0, 1, 2].map((i) => ({
    definition: {
      key: `${g.toLowerCase().replace(/\W/g, '')}.opt${i}`,
      group: g,
      type: 'integer',
      envName: `FORM_${gi}_OPT_${i}`,
      minimum: 1,
      maximum: 100,
      restartRequired: i === 1,
      sensitive: false,
    },
    value: String(10 * (i + 1)),
    source: ['env', 'db', 'default'][i],
    locked: i === 0,
  })),
);
for (const scheme of ['light', 'dark'] as const)
  test(`settings ${scheme}`, async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
    await page.route('**/admin/api/v1/**', (r) => {
      const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
      if (p === '/auth/session')
        return r.fulfill(
          j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
        );
      if (p === '/me')
        return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
      if (p === '/setup-state') return r.fulfill(j({ required: false }));
      if (p === '/settings') return r.fulfill(j({ revision: 'r', items }));
      return r.fulfill(j({ items: [] }));
    });
    await page.goto('/settings');
    await page.waitForLoadState('networkidle');
    await page.screenshot({ path: `${out}/settings-${scheme}.png`, fullPage: true });
  });
