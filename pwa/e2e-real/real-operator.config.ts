import { defineConfig } from '@playwright/test';

// Operator path (backend/e2e-operator.sh): the admin origin is https behind a TLS reverse proxy with a throw-away CA. Chromium trusts exactly
// that server key (SPKI pin), so the page is a secure context without certificate errors and WebAuthn works as in production.
export default defineConfig({
  testDir: '.',
  outputDir: process.env.E2E_OUTPUT_DIR ?? 'test-results',
  testMatch: process.env.E2E_SPEC ?? 'real-operator.spec.ts',
  timeout: 1_800_000,
  use: {
    baseURL: process.env.E2E_BASE_URL,
    browserName: 'chromium',
    actionTimeout: 30_000,
    navigationTimeout: 60_000,
    ignoreHTTPSErrors: true,
    launchOptions: {
      args: [`--ignore-certificate-errors-spki-list=${process.env.E2E_SPKI ?? ''}`],
    },
  },
  expect: { timeout: 30_000 },
});
