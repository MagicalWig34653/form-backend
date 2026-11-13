// SPDX-License-Identifier: AGPL-3.0-only
import { test, expect, type BrowserContext, type Page } from '@playwright/test';
import { env } from './helpers';

// Admin request limit in a real browser against the real backend + MariaDB (backend/e2e-admin-limit.sh).
// Part 1 (default limits): 20 page loads of the customer list / customer page within a minute, well over 120 API calls
// (the old IP limit), must not run into 429. Part 2 (account limit 5): the German message with the wait appears.
const part = process.env.E2E_ADMIN_LIMIT_PART ?? '1';

async function signIn(page: Page, context: BrowserContext) {
  const cdp = await context.newCDPSession(page);
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  await cdp.send('WebAuthn.addCredential', {
    authenticatorId,
    credential: {
      credentialId: env('E2E_CREDENTIAL_ID_B64'),
      isResidentCredential: true,
      rpId: env('E2E_RP_ID'),
      privateKey: env('E2E_PRIVATE_KEY_B64'),
      userHandle: env('E2E_USER_HANDLE_B64'),
      // Part 1 already advanced the sign counter stored in the database; a lower counter would count as a cloned key.
      signCount: part === '1' ? 0 : 10,
    },
  });
  await page.goto('/login');
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await page.getByLabel('Passwort').fill(env('E2E_PASSWORD'));
  await page.getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText('Sie sind angemeldet.')).toBeVisible();
}

test('part 1: 20 page loads within a minute do not hit the admin limit', async ({
  page,
  context,
}) => {
  test.skip(part !== '1');
  test.setTimeout(120_000);
  let calls = 0;
  const limited: string[] = [];
  page.on('response', (r) => {
    if (!r.url().includes('/admin/api/')) return;
    calls += 1;
    if (r.status() === 429) limited.push(r.url());
  });
  await signIn(page, context);
  const started = Date.now();
  const customer = env('E2E_CUSTOMER_NAME');
  for (let i = 0; i < 20; i++) {
    if (i % 2 === 0) {
      await page.goto('/t');
      await expect(page.getByRole('link', { name: `Öffnen: ${customer}` })).toBeVisible();
    } else {
      await page.goto(`/t/${env('E2E_CUSTOMER_ID')}`);
      await expect(page.getByText('Limitformular').first()).toBeVisible();
    }
    await page.waitForLoadState('networkidle');
  }
  const seconds = (Date.now() - started) / 1000;
  console.log(`admin API calls: ${calls} in ${seconds.toFixed(1)} s, 429: ${limited.length}`);
  expect(limited, 'no 429 responses').toEqual([]);
  expect(calls).toBeGreaterThan(process.env.E2E_ADMIN_LIMIT_WRONG === '1' ? 100000 : 120);
  expect(seconds).toBeLessThan(60);
});

test('part 2: with a small account limit the 429 message names the wait', async ({
  page,
  context,
}) => {
  test.skip(part !== '2');
  test.setTimeout(120_000);
  await signIn(page, context);
  const message = page.getByText(/Zu viele Anfragen\. Bitte in \d+ Sekunden erneut versuchen\./);
  for (let i = 0; i < 6 && !(await message.first().isVisible()); i++) {
    await page.goto('/t');
    await page.waitForLoadState('networkidle');
  }
  await expect(message.first()).toBeVisible();
  const seconds = Number(/(\d+) Sekunden/.exec(await message.first().innerText())?.[1]);
  expect(seconds).toBeGreaterThanOrEqual(1);
  expect(seconds).toBeLessThanOrEqual(60);
});
