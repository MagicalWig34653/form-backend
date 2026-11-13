import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  outputDir: process.env.E2E_OUTPUT_DIR ?? 'test-results',
  testMatch: process.env.E2E_SPEC ?? 'real-login.spec.ts',
  use: {
    baseURL: `http://localhost:${process.env.E2E_PORT ?? '4180'}`,
    browserName: 'chromium',
    actionTimeout: 20_000,
  },
});
