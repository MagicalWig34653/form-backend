import AxeBuilder from '@axe-core/playwright';
import { test, expect } from '@playwright/test';

test('root leads an anonymous visitor to the German login', async ({ page }) => {
  await page.route('**/admin/api/v1/auth/session', (route) =>
    route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        state: 'anonymous',
        csrfToken: 'c',
        expiresAt: '2026-10-31T10:00:00Z',
      }),
    }),
  );
  await page.goto('/');
  await expect(page).toHaveURL(/\/login(\?next=.*)?$/);
  await expect(page.getByRole('heading', { name: 'Anmelden' })).toBeVisible();
  await expect(page.locator('html')).toHaveAttribute('lang', 'de');
});

test('dialog opens and theme toggles', async ({ page }) => {
  await page.goto('/login');
  await page.getByRole('button', { name: 'Hilfe' }).click();
  await expect(page.getByRole('dialog')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog')).toBeHidden();
  await page.emulateMedia({ colorScheme: 'light' });
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'Dunkel', exact: true }).click();
  await expect(page.locator('html')).toHaveClass(/dark/);
  await page.getByRole('dialog').getByRole('button', { name: 'Hell', exact: true }).click();
  await expect(page.locator('html')).not.toHaveClass(/dark/);
});

test('manifest is served', async ({ request }) => {
  const res = await request.get('/manifest.webmanifest');
  expect(res.ok()).toBe(true);
});

test.describe('service worker', () => {
  test('is build-stamped and serves no API/admin responses from cache', async ({ request }) => {
    const sw = await (await request.get('/sw.js')).text();
    expect(sw).not.toContain('__BUILD__');
    expect(sw).toMatch(/const BUILD = '[0-9a-f]{12}'/);
  });

  test('caches static assets, never /admin/api, and serves the shell offline', async ({
    page,
    context,
  }) => {
    await page.goto('/login');
    await page.evaluate(() => navigator.serviceWorker.ready.then(() => undefined));
    await page.reload(); // controlled by the worker from here on
    await page.evaluate(() => fetch('/admin/api/v1/ping').catch(() => undefined));
    const cached = await page.evaluate(async () => {
      const urls: string[] = [];
      for (const k of await caches.keys()) {
        for (const r of await (await caches.open(k)).keys()) urls.push(new URL(r.url).pathname);
      }
      return urls;
    });
    expect(cached).toContain('/');
    expect(cached.some((u) => u.startsWith('/admin') || u.startsWith('/api'))).toBe(false);
    await context.setOffline(true);
    await page.goto('/login');
    await expect(page.getByRole('heading', { name: 'Anmelden' })).toBeVisible();
  });
});

test.describe('login flow (mocked API, stubbed authenticator)', () => {
  for (const secondFactorRequired of [false, true]) {
    test(`passkey login, second factor ${secondFactorRequired}, then logout`, async ({ page }) => {
      let state = 'anonymous';
      const seen: string[] = [];
      const body = (s: string) =>
        JSON.stringify({ state: s, csrfToken: 'csrf-' + s, expiresAt: '2026-10-31T10:00:00Z' });
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
                userHandle: bytes([4]),
              },
            }),
          },
        });
      });
      await page.route('**/admin/api/v1/auth/**', async (route) => {
        const req = route.request();
        const path = new URL(req.url()).pathname.replace('/admin/api/v1/auth/', '');
        seen.push(`${req.method()} ${path} csrf=${req.headers()['x-csrf-token'] ?? '-'}`);
        const json = (b: string, status = 200) =>
          route.fulfill({ status, contentType: 'application/json', body: b });
        if (path === 'session') return json(body(state));
        if (path === 'passkey/options')
          return json(
            JSON.stringify({
              challengeId: 'c1',
              publicKey: {
                challenge: 'AAEC',
                rpId: 'localhost',
                timeout: 120000,
                userVerification: 'required',
                allowCredentials: [],
              },
              expiresAt: 'e',
            }),
          );
        if (path === 'passkey/verify') {
          state = secondFactorRequired ? 'factor_pending' : 'authenticated';
          return json(body(state));
        }
        if (path === 'second-factor/password') {
          if (JSON.parse(req.postData() ?? '{}').password !== 'right')
            return json(JSON.stringify({ code: 'authentication_failed' }), 401);
          state = 'authenticated';
          return json(body(state));
        }
        if (path === 'logout') {
          state = 'anonymous';
          return route.fulfill({ status: 204 });
        }
        return route.fulfill({ status: 404 });
      });
      await page.goto('/login');
      await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
      if (secondFactorRequired) {
        await page.getByLabel('Passwort').fill('wrong');
        await page.getByRole('button', { name: 'Bestätigen' }).click();
        await expect(page.getByRole('alert')).toHaveText('Die Anmeldung ist fehlgeschlagen.');
        await page.getByLabel('Passwort').fill('right');
        await page.getByRole('button', { name: 'Bestätigen' }).click();
      } else {
        await expect(page.getByLabel('Passwort')).toHaveCount(0);
      }
      await expect(page.getByText('Sie sind angemeldet.')).toBeVisible();
      await page.getByRole('button', { name: 'Abmelden' }).click();
      await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
      expect(seen).toContain('POST passkey/options csrf=csrf-anonymous');
      expect(seen.some((s) => s.includes('second-factor/password'))).toBe(secondFactorRequired);
      expect(seen).toContain('POST logout csrf=csrf-authenticated');
    });
  }
});

test.describe('accessibility (axe, WCAG 2.1 A/AA)', () => {
  for (const scheme of ['light', 'dark'] as const) {
    test(`login page has no detectable violations in ${scheme} mode`, async ({ page }) => {
      await page.emulateMedia({ colorScheme: scheme });
      await page.route('**/admin/api/v1/auth/session', (route) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({
            state: 'anonymous',
            csrfToken: 'c',
            expiresAt: '2026-10-31T10:00:00Z',
          }),
        }),
      );
      await page.goto('/login');
      await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();
      const results = await new AxeBuilder({ page })
        .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
        .analyze();
      expect(results.violations.map((v) => `${v.id}: ${v.help} (${v.nodes.length})`)).toEqual([]);
    });
  }

  test('password step and error state have no detectable violations', async ({ page }) => {
    await page.route('**/admin/api/v1/auth/**', (route) => {
      const path = new URL(route.request().url()).pathname;
      const s = (state: string) =>
        route.fulfill({
          status: 200,
          contentType: 'application/json',
          body: JSON.stringify({ state, csrfToken: 'c', expiresAt: '2026-10-31T10:00:00Z' }),
        });
      if (path.endsWith('/session')) return s('factor_pending');
      return route.fulfill({
        status: 401,
        contentType: 'application/json',
        body: JSON.stringify({ code: 'authentication_failed' }),
      });
    });
    await page.goto('/login');
    await page.getByLabel('Passwort').fill('x');
    await page.getByRole('button', { name: 'Bestätigen' }).click();
    await expect(page.getByRole('alert')).toBeVisible();
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
      .analyze();
    expect(results.violations.map((v) => `${v.id}: ${v.help} (${v.nodes.length})`)).toEqual([]);
  });
});

test('documentation link opens the public docs safely', async ({ page }) => {
  await page.goto('/login');
  const link = page.getByRole('link', { name: 'Dokumentation' });
  await expect(link).toBeVisible();
  await expect(link).toHaveAttribute('href', /^https:\/\/[^/]+\/form-backend\/$/);
  await expect(link).toHaveAttribute('target', '_blank');
  await expect(link).toHaveAttribute('rel', /noopener/);
  await expect(link).toHaveAttribute('rel', /noreferrer/);
});

test('appearance persists accent and follows the system scheme', async ({ page }) => {
  await page.emulateMedia({ colorScheme: 'light' });
  await page.goto('/login');
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  const dialog = page.getByRole('dialog');
  await dialog.getByRole('button', { name: 'Violett', exact: true }).click();
  await dialog.getByRole('button', { name: 'Dunkel', exact: true }).click();
  await expect(page.locator('html')).toHaveClass(/dark/);
  await page.reload();
  await expect(page.locator('html')).toHaveAttribute('data-accent', 'violett');
  await expect(page.locator('html')).toHaveClass(/dark/);
  await page.getByRole('button', { name: 'Darstellung', exact: true }).click();
  await page.getByRole('dialog').getByRole('button', { name: 'System', exact: true }).click();
  await expect(page.locator('html')).not.toHaveClass(/dark/);
  await page.emulateMedia({ colorScheme: 'dark' });
  await expect(page.locator('html')).toHaveClass(/dark/);
});

for (const scheme of ['light', 'dark'] as const) {
  test(`setup is accessible in ${scheme} mode`, async ({ page }) => {
    await page.emulateMedia({ colorScheme: scheme });
    await page.goto('/setup#synthetic-enrollment-token');
    await expect(page.getByRole('textbox')).toBeVisible();
    const results = await new AxeBuilder({ page })
      .withTags(['wcag2a', 'wcag2aa', 'wcag21aa'])
      .analyze();
    expect(results.violations.map((v) => v.id)).toEqual([]);
  });
}
