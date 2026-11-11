import { test, expect, type Page } from '@playwright/test';
import type { KeyBundle } from '../src/lib/api/admin';
import { openAccess, wrapAccountKey, wrapAccountRecovery } from '../src/lib/crypto/keys';
import { fromBase64Url, identity, toBase64Url } from '../src/lib/crypto/packageV2';
import { LOGIN_PRF_SALT } from '../src/lib/api/webauthn';

// ADR 0037: legacy key adoption in the browser. Synthetic keys only; the API answers are mocked.
const T = 'aaaaaaaa-1111-4111-8111-11111111111a';
const accountSecret = new Uint8Array(32).fill(0x55);
const legacySecret = Uint8Array.from({ length: 32 }, (_, i) => (i * 29 + 3) & 0xff);

async function mock(page: Page) {
  const puts: { path: string; body: Record<string, string> }[] = [];
  let authenticated = false;
  const account = await identity(accountSecret);
  const legacy = await identity(legacySecret);
  const credentialId = Uint8Array.of(1, 2, 3);
  const wrap = await wrapAccountKey(accountSecret, new Uint8Array(32).fill(7), credentialId);
  const rec = await wrapAccountRecovery(accountSecret, 'ABCD-ABCD-ABCD-ABCD-ABCD-ABCD-ABCD-ABCD');
  const bundle: KeyBundle = {
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
    access: [], // the imported generation has no access yet
  };
  await page.addInitScript(() => {
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
            prf: { results: { first: new Uint8Array(32).fill(7).buffer } },
          }),
        }),
      },
    });
  });
  const j = (b: unknown, s = 200) => ({
    status: s,
    contentType: 'application/json',
    body: JSON.stringify(b),
  });
  await page.route('**/admin/api/v1/**', async (r) => {
    const p = new URL(r.request().url()).pathname.replace('/admin/api/v1', '');
    const method = r.request().method();
    if (p === '/auth/session')
      return r.fulfill(
        j({
          state: authenticated ? 'authenticated' : 'anonymous',
          csrfToken: 'c',
          subjectId: authenticated ? 'a' : undefined,
          expiresAt: 'x',
        }),
      );
    if (p === '/auth/passkey/options')
      return r.fulfill(
        j({
          challengeId: 'c1',
          publicKey: { challenge: 'AAEC', rpId: 'localhost', timeout: 120000 },
        }),
      );
    if (p === '/auth/passkey/verify') {
      authenticated = true;
      return r.fulfill(
        j({ state: 'authenticated', csrfToken: 'c', subjectId: 'a', expiresAt: 'x' }),
      );
    }
    if (p === '/me') return r.fulfill(j({ id: 'a', username: 'u', systemAdministrator: true }));
    if (p === '/setup-state') return r.fulfill(j({ required: false }));
    if (p === '/tenants')
      return r.fulfill(
        j({ items: [{ id: T, name: 'Kunde A', permissions: ['form.read', 'key.manage'] }] }),
      );
    if (p === '/me/key-bundle') return r.fulfill(j(bundle));
    if (p === '/me/totp') return r.fulfill(j({ enabled: false }));
    if (p === `/tenants/${T}/customer-key`)
      return r.fulfill(
        j({ keyId: legacy.kid, publicKey: toBase64Url(legacy.publicKey), generation: 1 }),
      );
    if (p === `/tenants/${T}/key-rotation`)
      return r.fulfill(
        j({
          active: { kid: legacy.kid, publicKey: toBase64Url(legacy.publicKey) },
          retiring: null,
          requested: false,
        }),
      );
    if (p === `/tenants/${T}/key-access/a` && method === 'PUT') {
      expect(r.request().headers()['x-csrf-token']).toBe('c');
      puts.push({ path: p, body: r.request().postDataJSON() as Record<string, string> });
      return r.fulfill(j({ status: 'created' }, 201));
    }
    return r.fulfill(j({ items: [] }));
  });
  return { puts, legacy };
}

async function signIn(page: Page) {
  await page.goto(`/login?next=${encodeURIComponent('/account?legacy=1')}`);
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await expect(page).toHaveURL(/\/account\?legacy=1$/);
}

test('legacy key adoption seals the old key to the own account key only', async ({ page }) => {
  const { puts, legacy } = await mock(page);
  await signIn(page);
  await expect(
    page.getByRole('heading', { name: 'Altschlüssel aus dem Umstieg übernehmen' }),
  ).toBeVisible();
  const field = page.getByLabel(/Alter privater Datenschlüssel/);
  await expect(field).toHaveAttribute('type', 'password');
  await expect(field).toHaveAttribute('autocomplete', 'off');
  await field.fill(toBase64Url(legacySecret));
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).click();
  await expect(
    page.getByText(new RegExp(`Zugang für die importierte Generation ${legacy.kid}`)),
  ).toBeVisible();
  await expect(field).toHaveValue('');
  expect(puts).toHaveLength(1);
  const body = puts[0]!.body;
  expect(Object.keys(body).sort()).toEqual(['enc', 'kid', 'sealed']);
  expect(body.kid).toBe(legacy.kid);
  expect(JSON.stringify(body)).not.toContain(toBase64Url(legacySecret));
  // the uploaded envelope opens with the account key and yields exactly the legacy key
  const opened = await openAccess(
    fromBase64Url(body.enc!),
    fromBase64Url(body.sealed!),
    accountSecret,
    legacy.kid,
  );
  expect(toBase64Url(opened)).toBe(toBase64Url(legacySecret));
  expect(
    await page.evaluate(() => JSON.stringify(localStorage) + JSON.stringify(sessionStorage)),
  ).not.toContain(toBase64Url(legacySecret));
});

test('a key that does not belong to the imported generation is refused without upload', async ({
  page,
}) => {
  const { puts } = await mock(page);
  await signIn(page);
  const field = page.getByLabel(/Alter privater Datenschlüssel/);
  await field.fill(toBase64Url(new Uint8Array(32).fill(0x11)));
  await page.getByRole('button', { name: 'Schlüssel prüfen und Zugang anlegen' }).click();
  await expect(page.getByText(/passt zu keiner importierten Schlüsselgeneration/)).toBeVisible();
  await expect(field).toHaveValue('');
  expect(puts).toHaveLength(0);
});
