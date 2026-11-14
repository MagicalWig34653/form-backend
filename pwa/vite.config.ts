import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Plugin } from 'vite';

/** Stamps a hash of the built files into dist/sw.js so each build uses its own cache. */
function swBuildStamp(): Plugin {
  return {
    name: 'sw-build-stamp',
    apply: 'build',
    writeBundle(options, bundle) {
      const dir = options.dir ?? 'dist';
      const hash = createHash('sha256');
      for (const name of Object.keys(bundle).sort()) hash.update(name);
      for (const f of ['index.html', 'theme-init.js', 'manifest.webmanifest', 'icon.svg']) {
        try {
          hash.update(readFileSync(`${dir}/${f}`));
        } catch {
          /* file not part of this build */
        }
      }
      const swPath = `${dir}/sw.js`;
      writeFileSync(
        swPath,
        readFileSync(swPath, 'utf8').replace("'__BUILD__'", `'${hash.digest('hex').slice(0, 12)}'`),
      );
    },
  };
}

export default defineConfig({
  plugins: [tailwindcss(), svelte(), swBuildStamp()],
  resolve: {
    alias: { $lib: fileURLToPath(new URL('./src/lib', import.meta.url)) },
    conditions: process.env.VITEST ? ['browser'] : undefined,
  },
  test: {
    environment: 'jsdom',
    include: ['src/**/*.test.ts'],
    setupFiles: ['src/test-setup.ts'],
    coverage: {
      provider: 'v8',
      // "all files under src" so that never-loaded files count as uncovered (the default only counts loaded files).
      include: ['src/**/*.{ts,svelte}'],
      // Justified exclusions: see /coverage-exclusions (keep both lists identical; scripts/coverage-ratchet.sh checks it).
      exclude: ['src/**/*.test.ts', 'src/**/*.d.ts', 'src/test-setup.ts', 'src/main.ts'],
      reporter: ['text-summary', 'json-summary', 'lcov'],
      reportsDirectory: 'coverage',
    },
  },
});
