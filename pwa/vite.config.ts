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
  },
});
