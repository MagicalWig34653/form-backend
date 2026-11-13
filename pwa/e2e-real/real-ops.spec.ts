// SPDX-License-Identifier: AGPL-3.0-only
import { test, expect } from '@playwright/test';

// Betrieb (ops) view in a real browser against the real backend + MariaDB (backend/e2e-ops.sh).
// Two real trigger events from two mail deliveries: "accepted", then "failed" (an open alarm), the failed one stamped ahead
// of the app clock (database clock drift). Both the alarm view (default) and the full list must show it.
const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

test('ops view lists events stamped ahead of the app clock', async ({ page, context }) => {
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
      signCount: 0,
    },
  });
  await page.goto('/login');
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await page.getByLabel('Passwort').fill(env('E2E_PASSWORD'));
  await page.getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText('Sie sind angemeldet.')).toBeVisible();

  // Default view: current alarms only. The open alarm (failed delivery) is stamped ahead of the app clock.
  const alarmResponse = page.waitForResponse(
    (r) => r.url().includes('/ops?') && r.request().method() === 'GET',
  );
  await page.goto('/ops');
  const res = await alarmResponse;
  expect(res.status()).toBe(200);
  expect(new URL(res.url()).searchParams.get('alarms')).toBe('1');
  await expect(page.locator('#ops-form option:checked')).toHaveText(env('E2E_OPS_FORM_NAME'));
  const rows = page.locator('table tbody tr');
  await expect(rows).toHaveCount(process.env.E2E_OPS_WRONG === '1' ? 2 : 1);
  await expect(rows.nth(0)).toContainText('Fehlgeschlagen');
  await expect(rows.nth(0)).toContainText('Mail');
  await expect(page.getByRole('heading', { name: 'Ereignisse (1)' })).toBeVisible();

  // All events: newest first, the drifted failed delivery leads, the accepted one follows.
  await page.getByText('Nur aktuelle Alarme').click();
  const allResponse = page.waitForResponse(
    (r) => r.url().includes('/ops?') && r.request().method() === 'GET',
  );
  await page.getByRole('button', { name: 'Anwenden' }).click();
  const all = await allResponse;
  expect(all.status()).toBe(200);
  expect(new URL(all.url()).searchParams.get('alarms')).toBeNull();
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0)).toContainText('Fehlgeschlagen');
  await expect(rows.nth(1)).toContainText('Angenommen');
  await expect(page.getByText('Keine passenden Ereignisse.')).toHaveCount(0);
});
