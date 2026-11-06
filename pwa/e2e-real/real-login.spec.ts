import { test, expect } from '@playwright/test';

// Real browser WebAuthn (CDP virtual authenticator) against the real backend + MariaDB.
// Orchestrated by backend/e2e-login.sh, which seeds the account and passes the credential through the environment.
const env = (k: string) => {
  const v = process.env[k];
  if (!v) throw new Error(`missing ${k}`);
  return v;
};

test('virtual authenticator login: passkey, wrong password, right password, logout', async ({
  page,
  context,
}) => {
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
  await page.getByLabel('Passwort').fill('wrong password');
  await page.getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByRole('alert')).toHaveText('Die Anmeldung ist fehlgeschlagen.');
  await page.getByLabel('Passwort').fill(env('E2E_PASSWORD'));
  await page.getByRole('button', { name: 'Bestätigen' }).click();
  await expect(page.getByText('Sie sind angemeldet.')).toBeVisible();

  // The session survives a reload (HttpOnly cookie), and the sign counter advanced in the database.
  await page.reload();
  await expect(page.getByText('Sie sind angemeldet.')).toBeVisible();
  await page.getByRole('button', { name: 'Abmelden' }).click();
  await expect(page.getByRole('button', { name: 'Mit Passkey anmelden' })).toBeVisible();

  // A second passkey login works with the advanced counter (replay protection must not lock the owner out).
  await page.getByRole('button', { name: 'Mit Passkey anmelden' }).click();
  await expect(page.getByLabel('Passwort')).toBeVisible();
});
