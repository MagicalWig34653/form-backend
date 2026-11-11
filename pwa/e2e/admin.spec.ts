import AxeBuilder from '@axe-core/playwright';
import { test, expect, type Page } from '@playwright/test';
import { createHash } from 'node:crypto';
import type { KeyBundle } from '../src/lib/api/admin';
import { grantAccess, wrapAccountKey, wrapAccountRecovery } from '../src/lib/crypto/keys';
import { identity, openPackage, parsePackage, toBase64Url } from '../src/lib/crypto/packageV2';
import { LOGIN_PRF_SALT } from '../src/lib/api/webauthn';
import fixture from '../src/lib/crypto/synthetic.fixture.json' with { type: 'json' };

const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const F = '22222222-2222-4222-8222-222222222222';
const D = '33333333-3333-4333-8333-333333333333';
const E = '44444444-4444-4444-8444-444444444444';
// Match the list with any query, but never detail, hold or deletion endpoints.
const isEntriesList = (url: URL) =>
  url.pathname === `/admin/api/v1/tenants/${T}/forms/${F}/entries`;
// PHP-sealed (sdk/php/tests harness) for the public synthetic test key (backend/Tests/FormCryptoTests/Fixtures/README.md)
const PACKAGE =
  'KUBUS-AEAD:2|d19bf3f082782c87|hpke|D6poTtKIZ7l/Smot7l34zpdOdrcBjj8iocTPJnhXDyA=:Naj+1VnNQUoDPZGcrjR6QK1K6sHAptjadvBhtvfcL71QwELCwAt8szBGkDyZiHjC|RERERERERERERERE|S7Oi+69q6xiCuN+wmPynFDi2M88SttQqxQOnAGqEcKV+Gt6LQhWVdFOgCo5AYV4RtBgE8ZO25uazXP+ER/XYkQljKZB+84sp0PIue42B+iSujNT5z7JA9KbtM9WU78+KdtzkXZwdXE6kGfo=|gBgiWLPFXSF2g1BxaEqjjA==';
const memberSaved: { permissions?: string[] }[] = [];
const resent: { deliveryId?: string; contentKey?: string }[] = [];
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

// Public synthetic fixture material only; never use these keys outside tests.
const K = 'd19bf3f082782c87';
const dataSecret = Uint8Array.from(Buffer.from(fixture.sk, 'hex'));
const sha256 = (wire: string) => createHash('sha256').update(wire).digest('hex');

async function mock(
  page: Page,
  unlock = false,
  noPrf = false,
): Promise<{ calls: string[]; holdRequests: unknown[] }> {
  const calls: string[] = [];
  let authenticated = !unlock;
  let held = false;
  let wire = PACKAGE;
  let revision = 1;
  const objectId = '55555555-5555-4555-8555-555555555555';
  const holdRequests: unknown[] = [];
  let bundle: KeyBundle | undefined;
  if (unlock) {
    const accountSecret = new Uint8Array(32).fill(0x55);
    const account = await identity(accountSecret);
    const credentialId = Uint8Array.of(1, 2, 3);
    const prfOutput = new Uint8Array(32).fill(7);
    const wrap = await wrapAccountKey(accountSecret, prfOutput, credentialId);
    const access = await grantAccess(dataSecret, account.publicKey, K);
    const rec = await wrapAccountRecovery(accountSecret, 'ABCD-ABCD-ABCD-ABCD-ABCD-ABCD-ABCD-ABCD');
    bundle = {
      recovery: {
        revision: 'synthetic',
        salt: toBase64Url(rec.salt),
        iterations: rec.iterations,
        iv: toBase64Url(rec.iv),
        wrap: toBase64Url(rec.wrap),
      },
      rpId: 'localhost',
      accountPublicKey: toBase64Url(account.publicKey),
      wraps: [
        {
          credentialId: toBase64Url(credentialId),
          prfSalt: toBase64Url(LOGIN_PRF_SALT),
          iv: toBase64Url(wrap.iv),
          wrap: toBase64Url(wrap.wrap),
        },
      ],
      access: [
        { tenantId: T, kid: K, enc: toBase64Url(access.enc), sealed: toBase64Url(access.sealed) },
      ],
    };
    await page.addInitScript((noPrf) => {
      const bytes = (n: number[]) => new Uint8Array(n).buffer;
      (window as unknown as { PublicKeyCredential: unknown }).PublicKeyCredential ??= class {};
      Object.defineProperty(navigator, 'credentials', {
        configurable: true,
        value: {
          get: async () => ({
            id: 'AQID',
            rawId: bytes([1, 2, 3]),
            type: 'public-key',
            response: {
              authenticatorData: bytes([1]),
              clientDataJSON: bytes([2]),
              signature: bytes([3]),
              userHandle: null,
            },
            getClientExtensionResults: () => ({
              prf: noPrf ? undefined : { results: { first: new Uint8Array(32).fill(7).buffer } },
            }),
          }),
        },
      });
    }, noPrf);
  }
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  // Register defaults first: Playwright gives later test-specific routes priority.
  await page.route('**/admin/api/v1/**', async (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    const f = `/tenants/${T}/forms/${F}`;
    if (p === '/auth/session')
      return r.fulfill(
        j({
          state: authenticated ? 'authenticated' : 'anonymous',
          csrfToken: 'c',
          subjectId: authenticated ? 'a' : undefined,
          expiresAt: 'x',
        }),
      );
    if (unlock && p === '/auth/passkey/options')
      return r.fulfill(
        j({
          challengeId: 'c1',
          publicKey: {
            challenge: 'AAEC',
            rpId: 'localhost',
            timeout: 120000,
            userVerification: 'required',
          },
        }),
      );
    if (unlock && p === '/auth/passkey/verify') {
      expect(r.request().postData()).not.toContain('prf');
      authenticated = true;
      return r.fulfill(
        j({
          state: 'authenticated',
          csrfToken: 'c',
          subjectId: authenticated ? 'a' : undefined,
          expiresAt: 'x',
        }),
      );
    }
    if (unlock && p === '/me/key-bundle') return r.fulfill(j(bundle));
    if (unlock && p.endsWith('/key-rotation'))
      return r.fulfill(
        j({
          active: { kid: K, publicKey: Buffer.from(fixture.pk, 'hex').toString('base64url') },
          retiring: null,
        }),
      );
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/tenants')
      return r.fulfill(
        j({
          items: [
            {
              id: T,
              name: 'Kunde A',
              permissions: ['form.read', 'draft.write', 'release.publish', 'key.manage'],
            },
            { id: 'bbbbbbbb-1111-4111-8111-11111111111b', name: 'Kunde B', permissions: [] },
          ],
        }),
      );
    if (p === `/tenants/${T}/forms`)
      return r.fulfill(
        j({
          items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: D }],
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
    if (p === `/tenants/${T}/connections`)
      return r.fulfill(j({ items: [{ id: 'c1', kind: 'smtp', name: 'Mailserver' }] }));
    if (p === `${f}/webhooks`) return r.fulfill(j({ items: [] }));
    if (p === `${f}/mail-deliveries`)
      return r.fulfill(
        j({
          items: [
            {
              id: 'd',
              submissionId: 's',
              kind: 'organisation',
              state: 'smtp-accepted',
              attempts: 1,
              fence: 1,
              transport: 'smtp',
              createdAt: '2026-10-31T10:00:00Z',
              updatedAt: '2026-10-31T10:00:00Z',
            },
            {
              id: 'dd',
              submissionId: E,
              kind: 'organisation',
              state: 'waiting-manual',
              attempts: 1,
              transport: 'smtp',
              createdAt: '2026-10-31T10:00:00Z',
              updatedAt: '2026-10-31T10:00:00Z',
            },
          ],
        }),
      );
    if (p === `${f}/entries/${E}/resends`) {
      resent.push(JSON.parse(r.request().postData() ?? '{}'));
      return r.fulfill(j({ deliveryId: 'dd', state: 'leased' }, 202));
    }
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
            {
              credentialId: 'AgI',
              label: 'Telefon',
              createdAt: '2026-10-02T10:00:00Z',
              unlocksKeys: false,
            },
          ],
        }),
      );
    if (p === `/tenants/${T}/members`)
      return r.fulfill(
        j({
          items: [
            { accountId: 'a', username: 'u', permissions: ['form.read'], inherited: [] },
            {
              accountId: 'b',
              username: 'zweite.person',
              permissions: ['form.read'],
              inherited: ['audit.read'],
            },
          ],
          assignable: ['content.read', 'form.read', 'key.manage'],
        }),
      );
    if (p === `/tenants/${T}/members/b/permissions`) {
      memberSaved.push(JSON.parse(r.request().postData() ?? '{}'));
      return r.fulfill({ status: 204 });
    }
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
    if (p === `${f}/entries/${E}/hold-objects`) {
      calls.push('hold-objects');
      return r.fulfill(
        j({
          items: [
            {
              id: objectId,
              kid: K,
              revision,
              ciphertext_sha256: sha256(wire),
              package: wire,
              formId: F,
              wrapKind: parsePackage(wire).wrap,
              held,
              sourceGenerationId: D,
            },
          ],
        }),
      );
    }
    if (p === `${f}/entries/${E}/hold`) {
      const body = r.request().postDataJSON();
      holdRequests.push(body);
      expect(r.request().method()).toBe('PUT');
      const expected = {
        objectId,
        expectedRevision: revision,
        expectedSha256: sha256(wire),
        sourceGenerationId: D,
      };
      if (body.held) {
        expect(body).toEqual({
          held: true,
          objects: [{ ...expected, replacementPackage: expect.any(String) }],
        });
        const replacement = body.objects[0].replacementPackage as string;
        expect(parsePackage(replacement).wrap).toBe('sym');
        expect(parsePackage(replacement).kid).toBe(K);
        expect(replacement.split('|').slice(4)).toEqual(wire.split('|').slice(4));
        expect(await openPackage(replacement, dataSecret)).toEqual(
          await openPackage(wire, dataSecret),
        );
        wire = replacement;
        revision++;
      } else {
        expect(body).toEqual({ held: false, objects: [expected] });
        expect(parsePackage(wire).wrap).toBe('sym');
      }
      held = body.held;
      calls.push(`hold ${held}`);
      return r.fulfill(j({ id: E, held }));
    }
    if (p === `${f}/entries/delete`) {
      calls.push(`delete ${r.request().postData()}`);
      return r.fulfill(j({ deleted: [E], held: [], missing: [] }));
    }
    if (p === `${f}/retention`) {
      if (r.request().method() === 'PUT') {
        calls.push(`retention ${r.request().postData()}`);
        return r.fulfill(j(JSON.parse(r.request().postData() ?? '{}')));
      }
      return r.fulfill(j({ days: 90 }));
    }
    if (p === `${f}/entries/local-access`)
      return r.fulfill(j({ canExport: true, canDelete: true }));
    if (p === `${f}/export/audit`) {
      expect(r.request().postDataJSON()).toEqual({});
      return r.fulfill({ status: 204 });
    }
    if (p === `${f}/export`) {
      calls.push('export');
      return r.fulfill(
        j({
          items: [
            {
              id: E,
              receivedAt: null,
              keyId: K,
              generationId: D,
              package: wire,
              attachments: 0,
            },
          ],
          nextCursor: null,
        }),
      );
    }
    if (p === `${f}/entries`)
      return r.fulfill(
        j({
          items: [
            {
              id: E,
              receivedAt: '2026-10-31T10:00:00Z',
              state: 'accepted',
              releaseId: D,
              keyId: 'd19bf3f082782c87',
              held,
            },
          ],
          nextCursor: null,
        }),
      );
    if (p === `${f}/entries/${E}/ciphertext`)
      return r.fulfill(
        j({
          id: E,
          keyId: 'd19bf3f082782c87',
          generationId: D,
          format: 'KUBUS-AEAD:2',
          package: PACKAGE,
        }),
      );
    if (p === `/tenants/${T}/customer-key`)
      return r.fulfill(j({ keyId: 'k1', publicKey: 'AAAA', generation: 1 }));
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
    return r.fulfill(j({}, 404));
  });
  // Returned for assertions without exposing or modifying the application's keyring.
  return { calls, holdRequests };
}

const pages: [string, string, string][] = [
  ['customers', '/t', 'Kunden'],
  ['forms', `/t/${T}`, 'Kunde A'],
  ['overview', `/t/${T}/f/${F}`, 'Kontakt'],
  ['fields', `/t/${T}/f/${F}/fields`, 'Felder & Ansicht'],
  ['mail', `/t/${T}/f/${F}/mail`, 'Mail'],
  ['publish', `/t/${T}/f/${F}/publish`, 'Veröffentlichung'],
  ['entries', `/t/${T}/f/${F}/entries`, 'Einsendungen'],
  ['account', '/account', 'Mein Konto'],
  ['members', `/t/${T}/members`, 'Mitglieder und Rechte'],
  ['formDirectory', '/forms', 'Formulare'],
  ['keys', `/t/${T}/f/${F}/keys`, 'PHP einbinden'],
  ['connections', '/connections', 'Verbindungen'],
  ['accounts', '/accounts', 'Konten'],
  ['settings', '/settings', 'Einstellungen'],
  ['tokens', '/api-tokens', 'API & MCP'],
];

test.describe('administration pages (mocked API) have no detectable axe violations', () => {
  for (const scheme of ['light', 'dark'] as const) {
    for (const [name, path, heading] of pages) {
      test(`${name} in ${scheme} mode`, async ({ page }) => {
        await page.emulateMedia({ colorScheme: scheme });
        await mock(page);
        await page.goto(path);
        await expect(page.getByRole('heading', { name: heading }).first()).toBeVisible();
        await page.waitForLoadState('networkidle');
        const results = await new AxeBuilder({ page })
          .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
          .analyze();
        expect(results.violations.map((v) => `${v.id}: ${v.help} (${v.nodes.length})`)).toEqual([]);
      });
    }
  }

  test('a field editor form is accessible and refuses a bad name locally', async ({ page }) => {
    await mock(page);
    await page.goto(`/t/${T}/f/${F}/fields`);
    await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
    await page.getByLabel('Technischer Name').fill('a b');
    await page.getByLabel('Beschriftung').fill('X');
    await page.getByRole('button', { name: 'Speichern', exact: true }).click();
    await expect(page.getByRole('alert')).toHaveText('Der Name ist ungültig.');
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();
    expect(results.violations.map((v) => v.id)).toEqual([]);
  });

  test('an expired session leads to the login with a return path', async ({ page }) => {
    await page.route('**/admin/api/v1/auth/session', (r) =>
      r.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ state: 'anonymous', csrfToken: 'c', expiresAt: 'x' }),
      }),
    );
    await page.goto(`/t/${T}/f/${F}/mail`);
    await expect(page).toHaveURL(
      new RegExp(`/login\\?next=${encodeURIComponent(`/t/${T}/f/${F}/mail`)}`),
    );
  });
});

test('Einsendungen bieten keine private Schlüsseleingabe und bleiben ohne Freigabe gesperrt', async ({
  page,
}) => {
  const { holdRequests } = await mock(page);
  await page.goto(`/t/${T}/f/${F}/entries`);
  await page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await expect(page.getByRole('menuitem', { name: 'Öffnen', exact: true })).toHaveAttribute(
    'aria-disabled',
    'true',
  );
  await expect(page.getByLabel(/Privater Datenschlüssel/)).toHaveCount(0);
  await expect(page.getByText(/Der Zugriff auf Einsendungen ist gesperrt/)).toBeVisible();
  await page.getByRole('menuitem', { name: 'Löschschutz setzen' }).click();
  await expect(page.getByRole('alert')).toHaveText(
    'Zum Umhängen müssen alte und neue Generation lokal entsperrt sein.',
  );
  expect(holdRequests).toEqual([]);
  await page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await expect(page.getByRole('menuitem', { name: 'Löschschutz setzen' })).toBeVisible();
});

test('hold, deletion and the sealed export work from the entries tab', async ({ page }) => {
  const { calls } = await mock(page, true);
  await page.goto(`/login?next=${encodeURIComponent(`/t/${T}/f/${F}/entries`)}`);
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await expect(page).toHaveURL(`/t/${T}/f/${F}/entries`);
  const menu = () => page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await menu();
  await expect(page.getByRole('menuitem', { name: 'Öffnen', exact: true })).toBeEnabled();
  await page.getByRole('menuitem', { name: 'Löschschutz setzen' }).click();
  await expect(page.locator('li').getByText('Geschützt', { exact: true })).toBeVisible();
  await menu();
  await page.getByRole('menuitem', { name: 'Löschschutz aufheben' }).click();
  await page
    .getByRole('alertdialog', { name: 'Löschschutz aufheben' })
    .getByRole('button', { name: 'Aufheben' })
    .click();
  await expect(page.locator('li').getByText('Geschützt', { exact: true })).toHaveCount(0);
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Verschlüsselt exportieren', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('Alle Einsendungen dieses Formulars');
  await page.getByRole('dialog').getByRole('button', { name: 'Exportieren', exact: true }).click();
  expect((await download).suggestedFilename()).toBe('einsendungen-verschluesselt.json');
  await page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await page.getByRole('menuitem', { name: 'Löschen', exact: true }).click();
  const confirm = page.getByRole('alertdialog');
  await expect(confirm.getByRole('button', { name: 'Abbrechen' })).toBeFocused();
  await confirm.getByRole('button', { name: 'Endgültig löschen' }).click();
  await expect(page.getByText(/Gelöscht: 1/)).toBeVisible();
  await expect(page.getByText('Noch keine Einsendungen.')).toBeVisible();
  expect(calls).toEqual([
    'hold-objects',
    'hold true',
    'hold-objects',
    'hold false',
    'export',
    `delete {"ids":["${E}"]}`,
  ]);
});

test('retention is set on the Aufbewahrung tab with a sticky save bar', async ({ page }) => {
  const { calls } = await mock(page, true);
  await page.goto(`/login?next=${encodeURIComponent(`/t/${T}/f/${F}/storage`)}`);
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await expect(page).toHaveURL(`/t/${T}/f/${F}/storage`);
  await expect(page.getByLabel('Einsendungen automatisch löschen')).toBeChecked();
  await expect(page.getByLabel('Aufbewahrung in Tagen')).toHaveValue('90');
  await expect(page.getByRole('region', { name: 'Änderungen speichern' })).toHaveCount(0);
  await page.getByRole('button', { name: '30 Tage' }).click();
  await expect(page.getByRole('region', { name: 'Änderungen speichern' })).toBeVisible();
  await page.getByRole('button', { name: 'Aufbewahrung speichern' }).click();
  // Shortening deletes existing entries: the dialog has to be confirmed first.
  await page.getByRole('button', { name: 'Speichern und löschen' }).click();
  await expect(page.getByText(/^Gespeichert · \d\d:\d\d$/)).toBeVisible();
  expect(calls).toContain('retention {"days":30}');
});

test('the overview shows events and conversion with an undefined zero-visit day', async ({
  page,
}) => {
  await mock(page);
  await page.goto(`/t/${T}/f/${F}`);
  await expect(page.getByRole('heading', { name: 'Statistik', exact: true })).toBeVisible();
  await page.getByText('Datentabelle anzeigen').click();
  const table = page.getByRole('table');
  await expect(table.getByRole('columnheader', { name: 'Besuche' })).toBeVisible();
  await expect(table.getByRole('columnheader', { name: 'Beginn' })).toBeVisible();
  await expect(table.getByRole('columnheader', { name: 'Absenden' })).toBeVisible();
  await expect(table.getByRole('columnheader', { name: 'Abbruch' })).toBeVisible();
  await expect(table.getByRole('cell', { name: '15 %', exact: true })).toBeVisible();
  await expect(table.getByRole('cell', { name: '—', exact: true }).first()).toBeVisible();
  await expect(page.getByText('25 %', { exact: true })).toBeVisible();
  const scan = await new AxeBuilder({ page }).analyze();
  expect(scan.violations).toEqual([]);
});

test('rights of another member are saved, the own row is read-only', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${T}/members`);
  await expect(page.getByRole('heading', { name: 'zweite.person' })).toBeVisible();
  await expect(page.getByText('Zusätzlich über System oder Gruppe: Protokoll lesen')).toBeVisible();
  const row = page.locator('li', { hasText: 'zweite.person' });
  await row.getByLabel('content.read').check();
  await row.getByRole('button', { name: 'Rechte speichern' }).click();
  expect(memberSaved).toHaveLength(1);
  expect(memberSaved[0]?.permissions).toEqual(['content.read', 'form.read']);
});

test('mobile drawer traps focus, closes with Escape and navigates', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  await mock(page);
  await page.goto(`/t/${T}`);
  const trigger = page.getByRole('button', { name: 'Navigation öffnen' });
  await trigger.click();
  const drawer = page.getByRole('dialog', { name: 'Hauptnavigation' });
  await expect(drawer).toBeVisible();
  await expect(drawer.locator(':focus')).toHaveCount(1);
  await page.keyboard.press('Shift+Tab');
  await expect(drawer.locator(':focus')).toHaveCount(1);
  const axe = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze();
  expect(axe.violations.map((v) => v.id)).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(drawer).toBeHidden();
  await expect(trigger).toBeFocused();
  await trigger.click();
  await drawer.getByRole('link', { name: 'Mein Konto', exact: true }).click();
  await expect(page).toHaveURL('/account');
  await expect(drawer).toBeHidden();
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), {
      timeout: 5000,
    })
    .toBe(true);
});

test('customer selection and contextual sidebar preserve existing routes', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${T}/f/${F}`);
  const nav = page.getByRole('navigation', { name: 'Hauptnavigation' });
  await expect(nav.getByRole('link', { name: 'Einsendungen', exact: true })).toHaveAttribute(
    'href',
    `/t/${T}/f/${F}/entries`,
  );
  // The top bar has no customer switch (thermoctl layout); the command palette offers every customer.
  await page.getByRole('button', { name: /^Suchen/ }).click();
  await page
    .getByRole('dialog', { name: 'Befehlspalette' })
    .getByRole('combobox', { name: 'Befehl oder Seite suchen' })
    .fill('Kunde B');
  await page.getByRole('option', { name: /Kunde B/ }).click();
  await expect(page).toHaveURL('/t/bbbbbbbb-1111-4111-8111-11111111111b');
});

for (const mode of ['light', 'dark'] as const) {
  test(`Formularliste: Suche, Filter und axe (${mode}, mobil)`, async ({ page }) => {
    await page.setViewportSize({ width: 320, height: 760 });
    await page.addInitScript((theme) => localStorage.setItem('theme', theme), mode);
    await mock(page);
    await page.goto(`/t/${T}`);
    await expect(page.getByRole('link', { name: 'Kontakt', exact: true })).toBeVisible();
    await page.getByLabel('Formulare suchen').fill('Unbekannt');
    await expect(page.getByText('Keine passenden Formulare.')).toBeVisible();
    await page.getByRole('button', { name: 'Filter zurücksetzen' }).click();
    await expect(page.getByRole('link', { name: 'Kontakt', exact: true })).toBeVisible();
    await page.getByLabel('Status', { exact: true }).selectOption('unpublished');
    await expect(page.getByText('Keine passenden Formulare.')).toBeVisible();
    expect(
      (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze())
        .violations,
    ).toEqual([]);
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),
    ).toBe(true);
  });
}

test('Formularliste: langsame API, Fehler und erneutes Laden', async ({ page }) => {
  await mock(page);
  let release!: () => void;
  const pending = new Promise<void>((resolve) => {
    release = resolve;
  });
  let first = true;
  await page.route(`**/tenants/${T}/forms?*`, async (route) => {
    if (!first) return route.fallback();
    first = false;
    await pending;
    await route.fulfill({ status: 503, contentType: 'application/json', body: '{}' });
  });
  await page.goto(`/t/${T}`);
  await expect(page.getByText('Das Laden dauert länger als erwartet …')).toBeVisible();
  release();
  await expect(page.getByText('Die Daten konnten nicht geladen werden.')).toBeVisible();
  await expect(page.getByText('Dieser Kunde hat noch kein Formular.')).toHaveCount(0);
  await page.getByRole('button', { name: 'Erneut versuchen' }).click();
  await expect(page.getByRole('link', { name: 'Kontakt', exact: true })).toBeVisible();
});

test('Kundenüberblick: Suche und ein einzelner Kunde bleiben erreichbar', async ({ page }) => {
  await mock(page);
  await page.route('**/admin/api/v1/tenants', (route) =>
    route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ items: [{ id: T, name: 'Kunde A', permissions: [] }] }),
    }),
  );
  await page.goto('/t');
  await expect(page.getByRole('heading', { name: 'Kunden', exact: true })).toBeVisible();
  await page.getByLabel('Name suchen').fill('Fehlt');
  await expect(page.getByText('Keine passenden Kunden.')).toBeVisible();
  await page.getByRole('button', { name: 'Filter zurücksetzen' }).click();
  await page.getByRole('link', { name: 'Öffnen: Kunde A' }).click();
  await expect(page.getByRole('link', { name: 'Kontakt', exact: true })).toBeVisible();
  await expect(page.getByRole('button', { name: 'Formular anlegen', exact: true })).toHaveCount(0);
});

for (const status of [200, 403, 404]) {
  test(`Formularliste: Leer- und Rechtezustände mit axe (${status})`, async ({ page }) => {
    await mock(page);
    await page.route(`**/tenants/${T}/forms?*`, (route) =>
      route.fulfill({
        status,
        contentType: 'application/json',
        body: JSON.stringify(status === 200 ? { items: [], nextCursor: null } : {}),
      }),
    );
    await page.goto(`/t/${T}`);
    const text =
      status === 200
        ? 'Dieser Kunde hat noch kein Formular.'
        : status === 403
          ? 'Dafür fehlt Ihnen die Berechtigung.'
          : 'Diese Seite ist nicht verfügbar.';
    await expect(page.getByText(text)).toBeVisible();
    expect(
      (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze())
        .violations,
    ).toEqual([]);
  });
}

for (const administrator of [true, false]) {
  test(`Kundenüberblick: keine Kunden (${administrator ? 'Administration' : 'ohne Freigabe'})`, async ({
    page,
  }) => {
    await mock(page);
    await page.route('**/admin/api/v1/me', (route) =>
      route.fulfill({
        contentType: 'application/json',
        body: JSON.stringify({ id: 'a', username: 'u', systemAdministrator: administrator }),
      }),
    );
    await page.route('**/admin/api/v1/tenants', (route) =>
      route.fulfill({ contentType: 'application/json', body: '{"items":[]}' }),
    );
    await page.goto('/t');
    await expect(
      page.getByText(
        administrator
          ? 'Noch keine Kunden vorhanden.'
          : 'Für Ihr Konto ist noch kein Kunde freigegeben.',
      ),
    ).toBeVisible();
    await expect(page.getByRole('button', { name: 'Kunde anlegen', exact: true })).toHaveCount(
      administrator ? 1 : 0,
    );
    expect(
      (await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21aa']).analyze())
        .violations,
    ).toEqual([]);
  });
}

test('entries filters, detail and export are accessible on a narrow screen', async ({ page }) => {
  // Hover transitions would make the measured contrast depend on timing.
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.setViewportSize({ width: 320, height: 740 });
  await mock(page, true);
  await page.goto(`/login?next=${encodeURIComponent(`/t/${T}/f/${F}/entries`)}`);
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await page.getByRole('menuitem', { name: 'Öffnen', exact: true }).click();
  const detail = page.getByRole('dialog');
  await expect(detail.getByRole('heading', { name: 'Einsendungsdetail' })).toBeVisible();
  await expect(detail.getByRole('button', { name: 'Schließen' })).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), {
      timeout: 5000,
    })
    .toBe(true);
  await page.keyboard.press('Escape');
  await expect(detail).toBeHidden();
  await page.getByText('Filter', { exact: true }).click();
  await page.getByRole('textbox', { name: 'Eingang von (UTC)' }).fill('01.01.2030');
  await expect(page.getByText('Keine Einsendungen für diese Filter.')).toBeVisible();
  await page.getByRole('button', { name: 'Verschlüsselt exportieren', exact: true }).click();
  await expect(page.getByRole('dialog')).toContainText('Alle Einsendungen dieses Formulars');
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(
    page.getByRole('button', { name: 'Verschlüsselt exportieren', exact: true }),
  ).toBeFocused();
  const local = page.getByRole('region', { name: 'Lokale Suche und Auskunft' });
  await local.getByRole('button', { name: 'Lokal durchsuchen', exact: true }).click();
  await expect(local.getByText('Treffer und ungeklärte Datensätze: 1')).toBeVisible();
  await expect(
    local.getByText('Nicht entschlüsselbar – Zugehörigkeit ungeklärt', { exact: true }),
  ).toHaveCount(0);
  await local.getByRole('button', { name: 'Alle sichtbaren Ergebnisse auswählen' }).click();
  for (const format of ['CSV', 'JSON']) {
    const download = page.waitForEvent('download');
    await local.getByRole('button', { name: `Auswahl als ${format}`, exact: true }).click();
    expect((await download).suggestedFilename()).toBe(`einsendungen.${format.toLowerCase()}`);
  }
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), {
      timeout: 5000,
    })
    .toBe(true);
});

test('entries distinguish slow, denied and empty responses', async ({ page }) => {
  await mock(page);
  let release: () => void = () => {};
  const wait = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route(isEntriesList, async (route) => {
    await wait;
    await route.fulfill({ status: 403, contentType: 'application/json', body: '{}' });
  });
  await page.goto(`/t/${T}/f/${F}/entries`);
  await expect(
    page.getByText('Das Laden dauert länger. Bitte warten Sie einen Moment.'),
  ).toBeVisible();
  release();
  await expect(page.getByText('Dafür fehlt Ihnen die Berechtigung.')).toBeVisible();
  await expect(page.getByText('Noch keine Einsendungen.')).toHaveCount(0);
  await page.route(isEntriesList, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ items: [], nextCursor: null }),
    }),
  );
  await page.getByRole('button', { name: 'Erneut versuchen' }).click();
  await expect(page.getByText('Noch keine Einsendungen.')).toBeVisible();
});

test('pending external deletion never appears as confirmed deletion', async ({ page }) => {
  await mock(page);
  await page.route(`**/forms/${F}/entries/delete`, (route) =>
    route.fulfill({
      status: 202,
      contentType: 'application/json',
      body: JSON.stringify({ deleted: [], held: [], missing: [], pending: [E] }),
    }),
  );
  await page.goto(`/t/${T}/f/${F}/entries`);
  await page.getByRole('button', { name: /Aktionen für Einsendung/ }).click();
  await page.getByRole('menuitem', { name: 'Löschen', exact: true }).click();
  await page.getByRole('button', { name: 'Endgültig löschen' }).click();
  await expect(page.getByText(/Gelöscht: 0.*Noch in Löschung: 1/)).toBeVisible();
  await expect(page.getByText(/Löschung läuft. Die Bestätigung steht noch aus./)).toBeVisible();
  await expect(page.getByText('Noch keine Einsendungen.')).toHaveCount(0);
});

test('cancelled export never downloads a partial file', async ({ page }) => {
  await mock(page);
  let release: () => void = () => {};
  const wait = new Promise<void>((resolve) => {
    release = resolve;
  });
  let downloads = 0;
  page.on('download', () => downloads++);
  await page.route(
    (url) => url.pathname === `/admin/api/v1/tenants/${T}/forms/${F}/export`,
    async (route) => {
      await wait;
      await route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ items: [], nextCursor: null }),
      });
    },
  );
  await page.goto(`/t/${T}/f/${F}/entries`);
  await page.getByRole('button', { name: 'Verschlüsselt exportieren', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Exportieren', exact: true }).click();
  await expect(page.getByText(/0 Einsendungen vorbereitet/)).toBeVisible();
  await page.getByRole('button', { name: 'Abbrechen', exact: true }).click();
  release();
  await expect(
    page.getByRole('button', { name: 'Verschlüsselt exportieren', exact: true }),
  ).toBeEnabled();
  expect(downloads).toBe(0);
});

test('mixed deletion keeps protected and pending entries visible', async ({ page }) => {
  await mock(page);
  const ids = ['a', 'b', 'c', 'd'];
  await page.route(isEntriesList, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        items: ids.map((id) => ({
          id,
          receivedAt: `2026-11-0${ids.indexOf(id) + 1}T10:00:00Z`,
          state: 'accepted',
          keyId: K,
          releaseId: D,
          held: id === 'b',
        })),
        nextCursor: null,
      }),
    }),
  );
  await page.route(`**/forms/${F}/entries/delete`, (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ deleted: ['a'], held: ['b'], missing: ['d'], pending: ['c'] }),
    }),
  );
  await page.goto(`/t/${T}/f/${F}/entries`);
  await expect(page.getByRole('checkbox', { name: /Einsendung vom/ })).toHaveCount(4);
  for (const checkbox of await page.getByRole('checkbox', { name: /Einsendung vom/ }).all())
    await checkbox.check();
  await expect(page.getByText('4 ausgewählt')).toBeVisible();
  await page.getByRole('button', { name: 'Löschen', exact: true }).first().click();
  await page.getByRole('button', { name: 'Endgültig löschen' }).click();
  await expect(
    page.getByText(
      /Gelöscht: 1. Geschützt: 1. Fehlgeschlagen oder nicht vorhanden: 1. Noch in Löschung: 1./,
    ),
  ).toBeVisible();
  await expect(page.getByRole('checkbox', { name: /Einsendung vom/ })).toHaveCount(3);
});
test('Formularnavigation erhält alte Ziele; der Ablauf-Platzhalter ist ausgeblendet', async ({
  page,
}) => {
  await mock(page);
  await page.goto(`/t/${T}/f/${F}/fields`);
  // Navigation uses ordinary links, with no incomplete ARIA tab keyboard model.
  await expect(page.getByRole('tab')).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Einbindung', exact: true })).toHaveAttribute(
    'href',
    `/t/${T}/f/${F}/keys`,
  );
  await expect(page.getByRole('link', { name: 'Ablauf', exact: true })).toHaveCount(0);
  await page.goto(`/t/${T}/f/${F}/flow`);
  await expect(page.getByRole('heading', { name: 'Statistik', exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Webhooks', exact: true }).click();
  await expect(page).toHaveURL(`/t/${T}/f/${F}/webhooks`);
  await expect(page.getByText('Noch kein Webhook eingerichtet.')).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('Leserecht zeigt Status und blendet Bearbeitungsaktionen aus', async ({ page }) => {
  await mock(page);
  await page.route('**/admin/api/v1/tenants', (r) =>
    r.fulfill({ json: { items: [{ id: T, name: 'Kunde A', permissions: ['form.read'] }] } }),
  );
  await page.goto(`/t/${T}/f/${F}`);
  await expect(page.getByRole('heading', { name: 'Kontakt', exact: true })).toBeVisible();
  await expect(page.getByRole('link', { name: 'Entwurf bearbeiten', exact: true })).toHaveCount(0);
  await expect(
    page.getByRole('link', { name: 'Prüfen & veröffentlichen', exact: true }),
  ).toHaveCount(0);
  await page.goto(`/t/${T}/f/${F}/fields`);
  await expect(page.getByRole('alert')).toHaveText('Dafür fehlt Ihnen die Berechtigung.');
  await expect(page.getByRole('button', { name: 'Feld hinzufügen' })).toHaveCount(0);
});

test('Fehler beim Entwurfsladen wird nicht als leerer Entwurf angezeigt', async ({ page }) => {
  await mock(page);
  await page.route(`**/forms/${F}/drafts/${D}`, (r) => r.fulfill({ status: 503, json: {} }));
  await page.goto(`/t/${T}/f/${F}/fields`);
  await expect(page.getByRole('alert')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Entwurf anlegen' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Erneut versuchen' })).toBeVisible();
});

test('Mail-Zustellfehler lässt die Vorlage bearbeitbar und bietet Retry', async ({ page }) => {
  await mock(page);
  await page.route(`**/forms/${F}/mail-deliveries?*`, (r) => r.fulfill({ status: 503, json: {} }));
  await page.goto(`/t/${T}/f/${F}/mail`);
  await expect(page.getByLabel('Absenderadresse')).toBeVisible();
  await expect(page.getByRole('alert')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Erneut versuchen' })).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('Mail: Auswahl und Zuweisung des Versandwegs widersprechen sich nie', async ({ page }) => {
  await mock(page);
  let assigned = false;
  await page.route(`**/forms/${F}/mail-connection`, (r) => {
    assigned = true;
    return r.fulfill({ status: 204 });
  });
  await page.goto(`/t/${T}/f/${F}/mail`);
  const select = page.getByLabel('Versandverbindung');
  const assign = page.getByRole('button', { name: 'Versandweg zuweisen' });
  // Nothing assigned: the list is not preselected, the badge says so, assigning is not offered.
  await expect(page.getByText('Kein Versandweg gewählt')).toBeVisible();
  await expect(select).toHaveValue('');
  await expect(assign).toBeDisabled();
  // Picked but not assigned: the page says so explicitly.
  await select.selectOption({ label: 'Mailserver (SMTP-Server)' });
  await expect(page.getByText('Ausgewählt, aber noch nicht zugewiesen.')).toBeVisible();
  await expect(page.getByText('Kein Versandweg gewählt')).toBeVisible();
  await assign.click();
  await expect.poll(() => assigned).toBe(true);
  await expect(page.getByText('Versandweg: Mailserver')).toBeVisible();
  await expect(page.getByText('Ausgewählt, aber noch nicht zugewiesen.')).toHaveCount(0);
  await expect(assign).toBeDisabled();
});

test.describe('Verbindung prüfen (Schritte aus dem Fehlercode)', () => {
  const answer = (page: Page, status: number, body: object, delay = 0) =>
    page.route('**/admin/api/v1/connections/c1/test', async (r) => {
      if (delay) await new Promise((res) => setTimeout(res, delay));
      return r.fulfill({
        status,
        contentType: 'application/json',
        body: JSON.stringify(body),
      });
    });

  test('Erfolg zeigt alle Schritte in Ordnung und den grünen Ergebniskasten', async ({ page }) => {
    await mock(page);
    await answer(page, 200, { ok: true });
    await page.goto('/connections');
    await page.getByRole('button', { name: /^Testen/ }).click();
    const steps = page.getByTestId('check-steps-c1');
    await expect(steps.getByRole('listitem')).toHaveCount(4);
    for (const id of ['dns', 'tcp', 'tls', 'auth'])
      await expect(page.getByTestId(`check-step-c1-${id}`)).toHaveAttribute('data-status', 'ok');
    await expect(page.getByTestId('check-result-c1')).toHaveAttribute('data-ok', 'true');
    await expect(page.getByText('Verbindung in Ordnung')).toBeVisible();
    await expect(page.getByText(/Gesamtdauer/)).toBeVisible();
    await expect(page.getByText('Getestet ·')).toBeVisible();
    // Rückweg: erneut prüfen ist möglich.
    await expect(page.getByRole('button', { name: /^Erneut prüfen/ })).toBeEnabled();
  });

  test('TLS-Fehler: dns und tcp in Ordnung, tls mit Rat, Anmeldung übersprungen', async ({
    page,
  }) => {
    await mock(page);
    await answer(page, 200, { ok: false, code: 'tls_failed', transient: false });
    await page.goto('/connections');
    await page.getByRole('button', { name: /^Testen/ }).click();
    await expect(page.getByTestId('check-step-c1-tls')).toHaveAttribute('data-status', 'failed');
    await expect(page.getByTestId('check-step-c1-dns')).toHaveAttribute('data-status', 'ok');
    await expect(page.getByTestId('check-step-c1-tcp')).toHaveAttribute('data-status', 'ok');
    await expect(page.getByTestId('check-step-c1-auth')).toHaveAttribute('data-status', 'skipped');
    const problem = page.getByTestId('check-problem-c1');
    await expect(problem).toContainText('Die verschlüsselte Verbindung konnte nicht hergestellt');
    await expect(problem).toContainText('Was kann ich tun?');
    await expect(page.getByTestId('check-result-c1')).toHaveAttribute('data-ok', 'false');
    await expect(page.getByText('Test fehlgeschlagen', { exact: true })).toBeVisible();
    // Rückweg: nach Korrektur gelingt die erneute Prüfung und ersetzt das Ergebnis.
    await page.unroute('**/admin/api/v1/connections/c1/test');
    await answer(page, 200, { ok: true });
    await page.getByRole('button', { name: /^Erneut prüfen/ }).click();
    await expect(page.getByTestId('check-result-c1')).toHaveAttribute('data-ok', 'true');
    await expect(page.getByTestId('check-problem-c1')).toHaveCount(0);
  });

  test('Unbekannter Code und Rate-Limit bleiben ohne erfundene Schritte', async ({ page }) => {
    await mock(page);
    await answer(page, 200, { ok: false, code: 'seltsam_xyz' });
    await page.goto('/connections');
    await page.getByRole('button', { name: /^Testen/ }).click();
    await expect(page.getByTestId('check-problem-c1')).toContainText('seltsam_xyz');
    await expect(page.getByTestId('check-steps-c1')).toHaveCount(0);
    await page.unroute('**/admin/api/v1/connections/c1/test');
    await answer(page, 429, { code: 'rate_limited' });
    await page.getByRole('button', { name: /^Erneut prüfen/ }).click();
    await expect(page.getByTestId('check-error-c1')).toContainText('zu oft gestartet');
  });

  test('Während der Prüfung warten die Schritte, die Anzeige ist busy', async ({ page }) => {
    await mock(page);
    await answer(page, 200, { ok: true }, 600);
    await page.goto('/connections');
    await page.getByRole('button', { name: /^Testen/ }).click();
    await expect(page.getByRole('button', { name: /^Prüfung läuft/ })).toBeDisabled();
    await expect(page.getByTestId('check-c1').locator('[aria-busy="true"]')).toBeVisible();
    await expect(page.getByTestId('check-steps-c1').getByRole('listitem')).toHaveCount(4);
    await expect(page.getByTestId('check-result-c1')).toBeVisible();
  });

  for (const scheme of ['light', 'dark'] as const) {
    test(`Fehlerergebnis ohne axe-Verstöße bei 320 px (${scheme})`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme, reducedMotion: 'reduce' });
      await page.setViewportSize({ width: 320, height: 800 });
      await mock(page);
      await answer(page, 200, { ok: false, code: 'auth_failed' });
      await page.goto('/connections');
      await page.getByRole('button', { name: /^Testen/ }).click();
      await expect(page.getByTestId('check-problem-c1')).toBeVisible();
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
      );
      expect(overflow).toBe(false);
      const results = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
        .analyze();
      expect(results.violations.map((v) => `${v.id}: ${v.help} (${v.nodes.length})`)).toEqual([]);
    });
  }
});

test('Ungespeicherte Feldänderungen bleiben nach abgebrochener Navigation erhalten', async ({
  page,
}) => {
  await mock(page);
  await page.goto(`/t/${T}/f/${F}/fields`);
  await page.getByRole('button', { name: 'Feld hinzufügen' }).click();
  await page.getByLabel('Beschriftung', { exact: true }).fill('Entwurf erhalten');
  await page.getByRole('link', { name: 'Einbindung', exact: true }).click();
  await page
    .getByRole('alertdialog', { name: 'Änderungen verwerfen' })
    .getByRole('button', { name: 'Abbrechen' })
    .click();
  await expect(page).toHaveURL(`/t/${T}/f/${F}/fields`);
  await expect(page.getByLabel('Beschriftung', { exact: true })).toHaveValue('Entwurf erhalten');
});

test('SDK-Datei wird nur bewusst ausgestellt und heruntergeladen', async ({ page }) => {
  await mock(page);
  let issued = 0;
  await page.route(`**/forms/${F}/sdk-credentials`, (r) => {
    issued++;
    return r.fulfill({ json: { formId: F, tenantId: T, signingSeed: 'synthetic-only' } });
  });
  await page.goto(`/t/${T}/f/${F}/keys`);
  await expect(page.getByRole('heading', { name: 'PHP einbinden', exact: true })).toBeVisible();
  expect(issued).toBe(0);
  await page.getByRole('button', { name: 'Zugangsdatei ausstellen' }).click();
  await expect(page.getByLabel('Zugangsdatei', { exact: true })).toBeVisible();
  expect(issued).toBe(1);
  const download = page.waitForEvent('download');
  await page.getByRole('button', { name: 'Zugangsdatei herunterladen' }).click();
  expect((await download).suggestedFilename()).toBe('form-backend-credentials.json');
  await page.getByRole('button', { name: 'Datei ausblenden' }).click();
  await expect(page.getByLabel('Zugangsdatei', { exact: true })).toHaveCount(0);
});

test('Einbindung zeigt eine PHP-Kurzanleitung mit kopierbarem Beispiel', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${T}/f/${F}/keys`);
  await expect(page.getByRole('heading', { name: 'Einsendung senden' })).toBeVisible();
  const code = page.getByLabel('Beispiel für PHP', { exact: true });
  await expect(code).toContainText("Credentials::fromFile('/etc/myapp/credentials.json')");
  await expect(code).toContainText('use FormBackend\\Client;');
  await page.getByRole('button', { name: 'Beispiel kopieren' }).click();
  await expect(page.getByText('Beispiel kopiert.').or(page.getByRole('alert'))).toBeVisible();
});

test('Veröffentlichungswiederholung nach Antwortverlust verwendet denselben Auftrag', async ({
  page,
}) => {
  await mock(page);
  let confirmations = 0;
  const requests: { key: string | undefined; body: unknown }[] = [];
  await page.route(`**/forms/${F}/publication-confirmations`, (r) => {
    confirmations++;
    return r.fulfill({
      json: { confirmationId: 'confirmation-once', expiresAt: '2099-01-01T00:00:00Z' },
    });
  });
  await page.route(`**/forms/${F}/releases`, (r) => {
    requests.push({
      key: r.request().headers()['idempotency-key'],
      body: r.request().postDataJSON(),
    });
    if (requests.length === 1) return r.abort('failed');
    return r.fulfill({
      json: { id: D, version: '2', publication: { confirmedAt: '2026-11-03T00:00:00Z' } },
    });
  });
  await page.goto(`/t/${T}/f/${F}/publish`);
  await page.getByLabel('Ich habe die Änderungen geprüft.').check();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect(page.getByRole('alert')).toBeVisible();
  await page.getByRole('button', { name: 'Jetzt veröffentlichen' }).click();
  await expect.poll(() => requests.length).toBe(2);
  expect(confirmations).toBe(1);
  expect(requests[0]).toEqual(requests[1]);
  expect(requests[0]?.key).toBeTruthy();
});

test('Langsames Laden reserviert Platz und lässt Formularnavigation verfügbar', async ({
  page,
}) => {
  await mock(page);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  await page.route(`**/forms/${F}/drafts/${D}`, async (r) => {
    await gate;
    await r.fulfill({ json: { id: D, revision: 1, hash: 'h', document: doc } });
  });
  try {
    await page.goto(`/t/${T}/f/${F}/fields`);
    await expect(page.getByText('Das dauert länger als üblich. Bitte warten Sie …')).toBeVisible({
      timeout: 8000,
    });
    await expect(page.getByRole('link', { name: 'Einbindung', exact: true })).toBeVisible();
    expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
  } finally {
    release();
  }
  await expect(page.getByRole('heading', { name: 'Felder & Ansicht', exact: true })).toBeVisible();
});

test('Leere Felder bieten Anlage und eine ausdrücklich benannte Vorschau', async ({ page }) => {
  await mock(page);
  await page.route(`**/forms/${F}/drafts/${D}`, (r) =>
    r.fulfill({
      json: {
        id: D,
        revision: 1,
        hash: 'h',
        document: { ...doc, form: { ...doc.form, fields: {} }, views: [] },
      },
    }),
  );
  await page.goto(`/t/${T}/f/${F}/fields`);
  await expect(page.getByText('Fügen Sie das erste Feld hinzu.')).toBeVisible();
  await page.getByRole('button', { name: 'Vorschau', exact: true }).click();
  await expect(page.getByRole('region', { name: 'Vorschau', exact: true })).toBeVisible();
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('Feldänderung erhält Kennung, Metadaten und sendet Ansichtsoptionen mit Revision', async ({
  page,
}) => {
  await mock(page);
  const imported = {
    ...doc,
    form: {
      ...doc.form,
      fields: {
        message: {
          ...doc.form.fields.message,
          label: { de: 'Nachricht', en: 'Message' },
          hidden: false,
          locked: false,
          sensitive: true,
          validation: { type: 'string', maxLength: 400 },
        },
      },
    },
  };
  await page.route(`**/forms/${F}/drafts/${D}`, async (r) => {
    if (r.request().method() === 'GET')
      return r.fulfill({ json: { id: D, revision: 1, hash: 'h', document: imported } });
    expect(r.request().headers()['if-match']).toBe('"1"');
    const next = r.request().postDataJSON();
    expect(Object.keys(next.form.fields)).toEqual(['message']);
    expect(next.form.fields.message).toMatchObject({
      name: 'nachricht',
      label: { de: 'Neue Nachricht', en: 'Message' },
      hidden: true,
      locked: false,
      sensitive: true,
      validation: { maxLength: 400 },
    });
    expect(next.views[0].steps[0].sections[0].fields[0]).toMatchObject({
      fieldId: 'message',
      readOnly: true,
      disabled: false,
    });
    return r.fulfill({ json: { id: D, revision: 2, hash: 'new-hash', document: next } });
  });
  await page.goto(`/t/${T}/f/${F}/fields`);
  await page.getByRole('button', { name: 'Aktionen für Feld Nachricht' }).click();
  await page.getByRole('menuitem', { name: 'Bearbeiten', exact: true }).click();
  await page.getByLabel('Beschriftung', { exact: true }).fill('Neue Nachricht');
  await page.getByLabel('Sichtbarkeit', { exact: true }).selectOption('hidden');
  await page.getByLabel('Schreibgeschützt', { exact: true }).check();
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByText('Entwurf · Stand 2')).toBeVisible();
});

test('Feldkonflikt erhält lokale Eingaben und überschreibt nicht automatisch', async ({ page }) => {
  await mock(page);
  let writes = 0;
  await page.route(`**/forms/${F}/drafts/${D}`, (r) => {
    if (r.request().method() === 'GET')
      return r.fulfill({ json: { id: D, revision: 1, hash: 'h', document: doc } });
    writes++;
    return r.fulfill({ status: 409, json: {} });
  });
  await page.goto(`/t/${T}/f/${F}/fields`);
  await page.getByRole('button', { name: 'Aktionen für Feld Nachricht' }).click();
  await page.getByRole('menuitem', { name: 'Bearbeiten', exact: true }).click();
  await page.getByLabel('Beschriftung', { exact: true }).fill('Nicht verlieren');
  await page.getByRole('button', { name: 'Speichern', exact: true }).click();
  await expect(page.getByRole('alert')).toHaveText(
    'Der Entwurf wurde geändert. Laden Sie den aktuellen Stand und prüfen Sie Ihre Änderungen.',
  );
  await expect(page.getByLabel('Beschriftung', { exact: true })).toHaveValue('Nicht verlieren');
  expect(writes).toBe(1);
  expect((await new AxeBuilder({ page }).analyze()).violations).toEqual([]);
});

test('Feldreihenfolge lässt sich mit einer Tastaturaktion ändern', async ({ page }) => {
  await mock(page);
  const second = {
    name: 'zweites',
    kind: 'text',
    label: { de: 'Zweites Feld' },
    required: false,
    hidden: false,
    locked: false,
    sensitive: false,
    validation: { type: 'string' },
  };
  const initial = {
    ...doc,
    form: { ...doc.form, fields: { ...doc.form.fields, second } },
    views: [
      {
        ...doc.views[0],
        steps: [
          {
            id: 'm',
            sections: [
              {
                id: 's',
                fields: [
                  { fieldId: 'message', readOnly: false, disabled: false },
                  { fieldId: 'second', readOnly: false, disabled: false },
                ],
              },
            ],
          },
        ],
      },
    ],
  };
  await page.route(`**/forms/${F}/drafts/${D}`, (r) => {
    if (r.request().method() === 'GET')
      return r.fulfill({ json: { id: D, revision: 1, hash: 'h', document: initial } });
    const next = r.request().postDataJSON();
    expect(
      next.views[0].steps[0].sections[0].fields.map((f: { fieldId: string }) => f.fieldId),
    ).toEqual(['second', 'message']);
    return r.fulfill({ json: { id: D, revision: 2, hash: 'new-hash', document: next } });
  });
  await page.goto(`/t/${T}/f/${F}/fields`);
  const up = page.getByRole('button', { name: 'Nach oben Zweites Feld', exact: true });
  await up.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByText('Entwurf · Stand 2')).toBeVisible();
  const list = page
    .locator('ul')
    .filter({ has: page.getByRole('button', { name: 'Aktionen für Feld Zweites Feld' }) });
  await expect(list.getByRole('listitem').first()).toContainText('Zweites Feld');
  // The move is announced in a live region with the new position.
  await expect(
    page.getByRole('status').filter({ hasText: 'Zweites Feld, Position 1 von 2' }),
  ).toBeAttached();
});

test('Alt+Pfeil verschiebt ein Feld direkt und sagt die Position an', async ({ page }) => {
  await mock(page);
  const mk = (id: string) => ({
    name: id,
    kind: 'text',
    label: { de: `Feld ${id}` },
    required: false,
    hidden: false,
    locked: false,
    sensitive: false,
    validation: { type: 'string' },
  });
  const initial = {
    ...doc,
    form: { ...doc.form, fields: { a: mk('a'), b: mk('b') } },
    views: [
      {
        ...doc.views[0],
        steps: [
          {
            id: 'm',
            sections: [
              {
                id: 's',
                fields: ['a', 'b'].map((fieldId) => ({
                  fieldId,
                  readOnly: false,
                  disabled: false,
                })),
              },
            ],
          },
        ],
      },
    ],
  };
  await page.route(`**/forms/${F}/drafts/${D}`, (r) => {
    if (r.request().method() === 'GET')
      return r.fulfill({ json: { id: D, revision: 1, hash: 'h', document: initial } });
    const next = r.request().postDataJSON();
    return r.fulfill({ json: { id: D, revision: 2, hash: 'n', document: next } });
  });
  await page.goto(`/t/${T}/f/${F}/fields`);
  await page.getByRole('button', { name: 'Nach oben Feld b', exact: true }).focus();
  await page.keyboard.press('Alt+ArrowUp');
  await expect(
    page.getByRole('status').filter({ hasText: 'Feld b, Position 1 von 2' }),
  ).toBeAttached();
  await expect(page.getByRole('button', { name: 'Nach unten Feld b', exact: true })).toBeFocused();
});

test('Befehlspalette: Strg+K, Filter, Pfeiltasten, Enter navigiert, Esc gibt den Fokus zurück', async ({
  page,
}) => {
  await mock(page);
  await page.goto(`/t/${T}`);
  const trigger = page.getByRole('button', { name: /^Suchen/ });
  await trigger.focus();
  await page.keyboard.press('Control+k');
  const dialog = page.getByRole('dialog', { name: 'Befehlspalette' });
  const input = dialog.getByRole('combobox', { name: 'Befehl oder Seite suchen' });
  await expect(input).toBeFocused();
  expect((await new AxeBuilder({ page }).analyze()).violations.map((v) => v.id)).toEqual([]);
  await page.keyboard.press('Escape');
  await expect(dialog).toBeHidden();
  await expect(trigger).toBeFocused();
  await trigger.click();
  await input.fill('einstell');
  await expect(dialog.getByRole('option')).toHaveCount(1);
  await input.fill('');
  await page.keyboard.press('ArrowDown');
  await expect(input).toHaveAttribute('aria-activedescendant', /palette-opt-/);
  await input.fill('konto');
  await page.keyboard.press('Enter');
  await expect(page).toHaveURL('/account');
  await expect(dialog).toBeHidden();
});

test('Leuchten wird pro Gerät gespeichert, die Akzentfarbe bleibt lesbar', async ({ page }) => {
  await mock(page);
  await page.goto(`/t/${T}`);
  const root = page.locator('html');
  await expect(root).not.toHaveAttribute('data-glow', 'on');
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByLabel('Leuchten').fill('4');
  await expect(root).toHaveAttribute('data-glow', 'on');
  await expect(root).toHaveAttribute('data-glow-step', '4');
  await dialog.getByRole('button', { name: 'Gelb', exact: true }).click();
  expect(await page.evaluate(() => localStorage.getItem('glow'))).toBe('4');
  await page.reload();
  await expect(root).toHaveAttribute('data-glow-step', '4');
  await expect(root).toHaveAttribute('data-accent', 'gelb');
  // yellow needs black text on primary buttons
  expect(await root.evaluate((el) => el.style.getPropertyValue('--primary-foreground'))).toBe(
    '#000000',
  );
});

test('Verbindungen: fehlendes Recht zeigt eine Meldung statt endloser Platzhalter', async ({
  page,
}) => {
  await mock(page);
  await page.route('**/admin/api/v1/connections', (r) =>
    r.request().method() === 'GET'
      ? r.fulfill({
          status: 403,
          contentType: 'application/json',
          body: JSON.stringify({ error: 'forbidden' }),
        })
      : r.fallback(),
  );
  await page.goto('/connections');
  await expect(page.getByText(/Recht der Systemadministration/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Erneut versuchen' })).toBeVisible();
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0);
});

test('Verbindungen: vorhandene Verbindung wird gelistet, Rendern wirft keinen Fehler', async ({
  page,
}) => {
  await mock(page);
  const errors: string[] = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.route('**/admin/api/v1/connections', (r) =>
    r.request().method() === 'GET'
      ? r.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
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
        })
      : r.fallback(),
  );
  await page.goto('/connections');
  await expect(page.locator('li p.font-medium', { hasText: 'Mailserver' })).toBeVisible();
  await expect(page.getByRole('button', { name: /^Testen/ }).first()).toBeVisible();
  expect(errors.filter((m) => /props_invalid_value/.test(m))).toEqual([]);
});

test('403 reauthentication_required: Umstiegsseite führt zur Passkey-Bestätigung statt zur Pauschalmeldung', async ({
  page,
}) => {
  await mock(page);
  let calls = 0;
  let loggedOut = false;
  await page.route('**/admin/api/v1/auth/logout', (r) => {
    loggedOut = true;
    return r.fulfill({ status: 204 });
  });
  await page.route('**/admin/api/v1/auth/session', (r) =>
    loggedOut
      ? r.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ state: 'anonymous', totpAllowed: false }),
        })
      : r.fallback(),
  );
  await page.route('**/admin/api/v1/migration/jobs', (r) => {
    calls += 1;
    return r.fulfill({
      status: 403,
      contentType: 'application/json',
      body: JSON.stringify({
        message: 'Bitte erneut anmelden, um diese Aktion zu bestätigen.',
        requestId: 'x',
        code: 'reauthentication_required',
      }),
    });
  });
  await page.goto('/migration');
  await expect(page).toHaveURL(/\/login\?next=%2Fmigration&reauth=1/);
  await expect(page.getByText(/Keine Berechtigung oder der Umstieg ist deaktiviert/)).toHaveCount(
    0,
  );
  expect(calls).toBeGreaterThan(0);
});
