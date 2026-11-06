import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: '.',
  testMatch: process.env.E2E_SPEC ?? 'real-login.spec.ts',
  use: { baseURL: `http://localhost:${process.env.E2E_PORT ?? '4180'}`, browserName: 'chromium' },
});
