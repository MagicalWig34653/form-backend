import { test, type Page } from '@playwright/test';

// Visual review helper: SHOTS=dir npx playwright test e2e/screens.spec.ts (skipped otherwise).
const out = process.env.SHOTS;
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';
const D = '33333333-3333-4333-8333-333333333333';
const E = '44444444-4444-4444-8444-444444444444';
const doc = {
  form: {
    id: F,
    version: '1.0.0',
    title: { de: 'Kontakt' },
    fields: {
      message: {
        name: 'nachricht',
        kind: 'text',
        label: { de: 'Nachricht' },
        required: true,
        validation: { type: 'string' },
      },
    },
  },
  views: [
    {
      id: 'v',
      version: '1.0.0',
      form: { id: F, version: '1.0.0', sha256: 'x' },
      steps: [{ id: 'm', sections: [{ id: 's', fields: [{ fieldId: 'message' }] }] }],
    },
  ],
};
const j = (b: unknown, s = 200) => ({
  status: s,
  contentType: 'application/json',
  body: JSON.stringify(b),
});
async function mock(page: Page) {
  await page.route('**/admin/api/v1/**', (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    const f = `/tenants/${T}/forms/${F}`;
    if (p === '/auth/session')
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'admin', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
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
            { id: 'bbbbbbbb-1111-4111-8111-11111111111b', name: 'Kunde B', permissions: [] },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [
            { id: F, name: 'Kontakt', active: true, currentReleaseId: D },
            { id: 'cc', name: 'Newsletter', active: false, currentReleaseId: null },
          ],
          nextCursor: null,
        }),
      );
    if (p === f)
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
    if (p === `${f}/drafts/${D}`)
      return r.fulfill(j({ id: D, revision: 1, hash: 'h', document: doc }));
    if (p === `${f}/entries`)
      return r.fulfill(
        j({
          items: [
            {
              id: E,
              receivedAt: '2026-10-31T10:00:00Z',
              state: 'accepted',
              releaseId: D,
              keyId: 'k',
              held: false,
            },
          ],
          nextCursor: null,
        }),
      );
    if (p === `${f}/statistics`)
      return r.fulfill(
        j({
          from: '2026-10-03',
          to: '2026-11-01',
          total: 5,
          visits: 20,
          begins: 12,
          submits: 5,
          abandons: 3,
          conversion: 0.25,
          days: [
            {
              date: '2026-10-31',
              count: 3,
              visits: 20,
              begins: 10,
              submits: 3,
              abandons: 2,
              conversion: 0.15,
            },
            {
              date: '2026-11-01',
              count: 2,
              visits: 0,
              begins: 2,
              submits: 2,
              abandons: 1,
              conversion: null,
            },
          ],
        }),
      );
    if (p === `/tenants/${T}/members`)
      return r.fulfill(
        j({
          items: [{ accountId: 'a', username: 'admin', permissions: ['form.read'], inherited: [] }],
          assignable: ['form.read', 'key.manage'],
        }),
      );
    if (p === '/me/passkeys')
      return r.fulfill(
        j({
          items: [
            {
              credentialId: 'AQE',
              label: 'Laptop',
              createdAt: '2026-10-01T10:00:00Z',
              unlocksKeys: true,
            },
          ],
        }),
      );
    if (p === '/settings')
      return r.fulfill(
        j({
          revision: 'r',
          items: [
            {
              definition: {
                key: 'mcp.requestsPerMinute',
                group: 'MCP',
                envName: 'X',
                type: 'integer',
                restartRequired: false,
              },
              value: '60',
              source: 'default',
              locked: false,
            },
          ],
        }),
      );
    if (p === '/connections')
      return r.fulfill(
        j({
          items: [
            {
              id: 'c1',
              kind: 'smtp',
              name: 'Mailserver',
              enabled: true,
              hasCredential: false,
              config: {},
            },
          ],
        }),
      );
    return r.fulfill(j({ items: [] }));
  });
}
const routes: [string, string][] = [
  ['gesamt', '/overview'],
  ['formularverzeichnis', '/forms'],
  ['kunden', '/t'],
  ['formulare', `/t/${T}`],
  ['formular', `/t/${T}/f/${F}`],
  ['felder', `/t/${T}/f/${F}/fields`],
  ['einsendungen', `/t/${T}/f/${F}/entries`],
  ['mail', `/t/${T}/f/${F}/mail`],
  ['veroeffentlichen', `/t/${T}/f/${F}/publish`],
  ['einbindung', `/t/${T}/f/${F}/keys`],
  ['mitglieder', `/t/${T}/members`],
  ['konto', '/account'],
  ['tokens', '/api-tokens'],
  ['einstellungen', '/settings'],
  ['verbindungen', '/connections'],
  ['einrichtung', '/installation'],
  ['umstieg', '/migration'],
  ['betrieb', '/ops'],
];
test.describe('screenshots', () => {
  test.skip(!out, 'set SHOTS');
  for (const scheme of ['light', 'dark'] as const)
    for (const [size, viewport] of [
      ['desktop', { width: 1280, height: 800 }],
      ['mobil', { width: 390, height: 800 }],
    ] as const)
      test(`${scheme} ${size}`, async ({ page }) => {
        test.setTimeout(240_000);
        await page.setViewportSize(viewport);
        await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
        await mock(page);
        for (const [name, path] of routes) {
          await page.goto(path);
          await page.waitForLoadState('networkidle');
          await page.screenshot({
            path: `${out}/${name}-${scheme === 'light' ? 'hell' : 'dunkel'}-${size}.png`,
            fullPage: true,
          });
        }
      });
});
