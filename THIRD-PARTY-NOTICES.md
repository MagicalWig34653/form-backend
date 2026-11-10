# Third-Party Notices

This repository is licensed under **AGPL-3.0-only** (see `LICENSE`). It uses
the third-party components listed below. Their licenses are *not* changed by
this repository's license. Full license texts / copyright notices that must
accompany redistribution are collected in [`LICENSES/`](LICENSES/).

- Generated: 2026-11-06 from the pinned versions in `backend/Package.resolved`,
  `pwa/package-lock.json` (installed with `npm ci --ignore-scripts`) and the
  SwiftPM checkouts (license files read from the checkouts).
- "Use" column: **runtime** = linked into / shipped with a deployed artifact;
  **build** = needed only to build; **test** = only for tests/CI.
- Compatibility: every license below is compatible with distribution inside an
  AGPL-3.0-only combined work (assessment, not legal advice). Apache-2.0 is
  compatible with GPLv3/AGPLv3 (not with GPLv2-only; none is used).

## Contents

1. [Summary and findings ("Auffaelligkeiten")](#1-findings)
2. [Backend (SwiftPM)](#2-backend-swiftpm)
3. [PWA - bundled into the delivered app](#3-pwa---bundled-into-the-delivered-app)
4. [PWA - build/test tooling (not distributed)](#4-pwa---buildtest-tooling-not-distributed)
5. [PHP SDK](#5-php-sdk)
6. [Fonts, icons, assets](#6-fonts-icons-assets)
7. [Agent roles (VoltAgent)](#7-agent-roles-voltagent)
8. [Out of scope / deployment images](#8-out-of-scope)

## 1. Findings

Rows marked **ACTION** need a decision or a change before/at publication.

| # | Item | License | Issue | Recommendation | Status |
|---|------|---------|-------|----------------|--------|
| 2 | Swift: BoringSSL code inside swift-crypto and swift-nio-ssl | ISC + OpenSSL + SSLeay | BoringSSL mixes ISC with the original OpenSSL/SSLeay licenses, which contain an advertising clause; the FSF considers the OpenSSL license GPL-incompatible. Practical risk is low (system-library style use of Apple packages by many GPL/AGPL projects), but it is a recognised grey area. | Keep `LICENSES/Swift-embedded-components.txt` with every binary/image release. **ACTION (medium):** have a human/legal check confirm acceptance before publication; no drop-in replacement exists for swift-crypto/NIO-SSL. | needs human judgement |
| 3 | Argon2 (`phc-winner-argon2`) | CC0-1.0 OR Apache-2.0 | Dual license; choose one. | Treat as **Apache-2.0** (attribution via `LICENSES/Argon2-CC0-1.0-OR-Apache-2.0.txt`) or CC0 (no attribution). No problem. | OK |
| 4 | axe-core, @axe-core/playwright | MPL-2.0 | Weak copyleft (file level). Used only for a11y tests; not distributed, not modified. | None needed. If ever bundled/modified, MPL source must be offered for modified files. | OK (test only) |
| 5 | lightningcss (+ ~13 platform binaries) | MPL-2.0 | Build-time CSS transformer (via Tailwind); its code is not part of the output. | None needed. | OK (build only) |
| 6 | argparse | Python-2.0 | Dev tool (eslint dependency), not distributed. PSF-style license is permissive; GPL-compatible. | None. | OK (dev only) |
| 7 | mdn-data | CC0-1.0 | Dev dependency (data), public-domain dedication. | None. | OK |
| 8 | svelte-toolbelt | (missing in package.json) | npm metadata lacks the `license` field; the shipped LICENSE file is MIT (Hunter Johnston, Thomas G. Lopes). It is bundled into the PWA via bits-ui. | Documented as MIT. No action. | OK |
| 9 | is-reference, locate-character | MIT (metadata) | Packages ship no LICENSE file (only the `license` field). Transitive dependencies of the Svelte compiler (listed conservatively in the bundled set). | Documented as MIT per metadata. | OK |
| 10 | shadcn-svelte derived components | MIT | MIT notice must be retained. Already in `pwa/SHADCN-LICENSE.md`. | Keep file; also referenced in `LICENSES/MIT.txt`. The comment in `pwa/src/app.css` also mentions "timetrack-pwa" - confirm by hand that this is the project's own code (no third-party rights). | check by hand |
| 11 | VoltAgent agent roles (`.claude/agents/vg-*.md`) | MIT | Attribution: MIT notice must accompany copies. Files only carry a one-line source comment. | `LICENSES/VoltAgent-awesome-claude-code-subagents-MIT.txt` added. **ACTION (low):** optional: add the copyright line to each `vg-*.md` header. | OK/low |
| 12 | Backend: Apache-2.0 NOTICE files | Apache-2.0 | Section 4(d): NOTICE contents must be reproduced in redistribution (source ok; binary/Docker image: ship the notices). | Collected in `LICENSES/Apache-2.0.txt`. **ACTION (low):** include `THIRD-PARTY-NOTICES.md` + `LICENSES/` in the release/Docker image (`COPY` in backend/Dockerfile) - not done here (no source changes). | open |
| 13 | Swift toolchain runtime libraries / Docker base images | Apache-2.0 w/ Runtime Library Exception; Ubuntu packages (GPL etc.) | Not in repo; added by `swift:6.3-noble-slim`. | Not part of this repository's source; image-level notices come from the base image. See section 8. | out of scope |
| 14 | Icons (`icon.svg`, PNG icons) | own work (assumed) | Simple geometric shapes; no third-party icon set found. | Confirm by hand authorship; then declare as AGPL-3.0-only (or CC0). | check by hand |
| 15 | PHP SDK | AGPL-3.0-only, no external Composer dependencies | PHP extensions (sodium/curl/json/mbstring) are runtime environment, not distributed. | None. | OK |

No GPL-2.0-only, UNLICENSED, proprietary, SSPL, BUSL or "unknown" license was
found among the pinned dependencies. The only metadata gap is item 8.

## 2. Backend (SwiftPM)

Source: `backend/Package.swift`, `backend/Package.resolved`. All packages are
linked into the `App` executable (**runtime**); test-only products (XCTVapor)
come from the same packages. "Direct" = declared in `Package.swift`; others
are transitive. Linkage of each transitive package into the final binary was
not verified individually. Notices: `LICENSES/Apache-2.0.txt`,
`LICENSES/MIT.txt`, `LICENSES/Argon2-CC0-1.0-OR-Apache-2.0.txt`,
`LICENSES/Swift-embedded-components.txt`.

| Component | Version | SPDX | Direct | Source | Use | Notice file |
|-----------|---------|------|--------|--------|-----|-------------|
| async-http-client | 1.36.2 | Apache-2.0 | no | https://github.com/swift-server/async-http-client | runtime | LICENSE.txt, NOTICE.txt |
| async-kit | 1.22.0 | MIT | no | https://github.com/vapor/async-kit | runtime | LICENSE |
| console-kit | 4.16.2 | MIT | no | https://github.com/vapor/console-kit | runtime | LICENSE |
| fluent | 4.13.0 | MIT | yes | https://github.com/vapor/fluent | runtime | LICENSE |
| fluent-kit | 1.57.0 | MIT | no | https://github.com/vapor/fluent-kit | runtime | LICENSE |
| fluent-mysql-driver | 4.8.0 | MIT | yes | https://github.com/vapor/fluent-mysql-driver | runtime | LICENSE |
| multipart-kit | 4.7.1 | MIT | no | https://github.com/vapor/multipart-kit | runtime | LICENSE |
| mysql-kit | 4.10.2 | MIT | no | https://github.com/vapor/mysql-kit | runtime | LICENSE |
| mysql-nio | 1.9.2 | MIT | no | https://github.com/vapor/mysql-nio | runtime | LICENSE |
| phc-winner-argon2 | rev f57e61e19229 | CC0-1.0 OR Apache-2.0 | yes | https://github.com/P-H-C/phc-winner-argon2 | runtime | LICENSE |
| routing-kit | 4.9.3 | MIT | no | https://github.com/vapor/routing-kit | runtime | LICENSE |
| sql-kit | 3.36.0 | MIT | no | https://github.com/vapor/sql-kit | runtime | LICENSE |
| swift-algorithms | 1.2.1 | Apache-2.0 | no | https://github.com/apple/swift-algorithms | runtime | LICENSE.txt |
| swift-asn1 | 1.7.3 | Apache-2.0 | no | https://github.com/apple/swift-asn1 | runtime | LICENSE.txt, NOTICE.txt |
| swift-async-algorithms | 1.1.7 | Apache-2.0 | no | https://github.com/apple/swift-async-algorithms | runtime | LICENSE.txt |
| swift-atomics | 1.3.1 | Apache-2.0 | no | https://github.com/apple/swift-atomics | runtime | LICENSE.txt |
| swift-certificates | 1.21.1 | Apache-2.0 | no | https://github.com/apple/swift-certificates | runtime | LICENSE.txt, NOTICE.txt |
| swift-collections | 1.7.5 | Apache-2.0 | no | https://github.com/apple/swift-collections | runtime | LICENSE.txt |
| swift-configuration | 1.4.0 | Apache-2.0 | no | https://github.com/apple/swift-configuration | runtime | LICENSE.txt, NOTICE.txt |
| swift-crypto | 3.15.1 | Apache-2.0 | yes | https://github.com/apple/swift-crypto | runtime | LICENSE.txt, NOTICE.txt |
| swift-distributed-tracing | 1.7.3 | Apache-2.0 | no | https://github.com/apple/swift-distributed-tracing | runtime | LICENSE.txt |
| swift-http-structured-headers | 1.7.0 | Apache-2.0 | no | https://github.com/apple/swift-http-structured-headers | runtime | LICENSE.txt |
| swift-http-types | 1.8.0 | Apache-2.0 | no | https://github.com/apple/swift-http-types | runtime | LICENSE.txt, NOTICE.txt |
| swift-log | 1.16.2 | Apache-2.0 | no | https://github.com/apple/swift-log | runtime | LICENSE.txt, NOTICE.txt |
| swift-metrics | 2.13.0 | Apache-2.0 | no | https://github.com/apple/swift-metrics | runtime | LICENSE.txt, NOTICE.txt |
| swift-nio | 2.104.0 | Apache-2.0 | no | https://github.com/apple/swift-nio | runtime | LICENSE.txt, NOTICE.txt |
| swift-nio-extras | 1.35.2 | Apache-2.0 | no | https://github.com/apple/swift-nio-extras | runtime | LICENSE.txt, NOTICE.txt |
| swift-nio-http2 | 1.46.0 | Apache-2.0 | no | https://github.com/apple/swift-nio-http2 | runtime | LICENSE.txt, NOTICE.txt |
| swift-nio-ssh | 0.12.0 | Apache-2.0 | yes | https://github.com/apple/swift-nio-ssh | runtime | LICENSE.txt |
| swift-nio-ssl | 2.37.5 | Apache-2.0 | no | https://github.com/apple/swift-nio-ssl | runtime | LICENSE.txt, NOTICE.txt |
| swift-nio-transport-services | 1.28.0 | Apache-2.0 | no | https://github.com/apple/swift-nio-transport-services | runtime | LICENSE.txt |
| swift-numerics | 1.1.1 | Apache-2.0 | no | https://github.com/apple/swift-numerics | runtime | LICENSE.txt |
| swift-service-context | 1.5.1 | Apache-2.0 | no | https://github.com/apple/swift-service-context | runtime | LICENSE.txt, NOTICE.txt |
| swift-service-lifecycle | 2.13.0 | Apache-2.0 | no | https://github.com/swift-server/swift-service-lifecycle | runtime | LICENSE.txt, NOTICE.txt |
| swift-system | 1.8.1 | Apache-2.0 | no | https://github.com/apple/swift-system | runtime | LICENSE.txt |
| vapor | 4.122.3 | MIT | yes | https://github.com/vapor/vapor | runtime | LICENSE, NOTICES.txt |
| websocket-kit | 2.16.2 | MIT | no | https://github.com/vapor/websocket-kit | runtime | LICENSE, NOTICES.txt |

Embedded third-party code inside those packages (compiled into the binary):
BoringSSL (ISC/OpenSSL/SSLeay; swift-crypto, swift-nio-ssl), llhttp (MIT;
swift-nio), FreeBSD sha1 (BSD-3-Clause; swift-nio), zlib (zlib license;
swift-nio-extras), plus code derived from Netty/grpc-swift/AsyncHTTPClient
etc. (Apache-2.0). See `LICENSES/Swift-embedded-components.txt`.

## 3. PWA - bundled into the delivered app

`pwa/package.json` lists **all** packages under `devDependencies` (Vite builds a
static bundle); there are no `dependencies`, so `npm ls --omit=dev` is empty.
The table below is the transitive closure of the packages that end up in (or
are imported at runtime by) the bundle: `svelte`, `bits-ui`, `clsx`,
`tailwind-merge` and their dependencies, determined from `package-lock.json`
(not by inspecting the built output - see handoff, "Luecken"). Compile-time-only
parts (e.g. aria-query, acorn used by the Svelte compiler) are included
conservatively.

| Component | Version | SPDX | Source | Use |
|-----------|---------|------|--------|-----|
| svelte | 5.57.3 | MIT | https://github.com/sveltejs/svelte | runtime (bundled) |
| @jridgewell/remapping | 2.3.5 | MIT | https://github.com/jridgewell/sourcemaps | runtime (bundled) |
| @jridgewell/gen-mapping | 0.3.13 | MIT | https://github.com/jridgewell/sourcemaps | runtime (bundled) |
| @jridgewell/sourcemap-codec | 1.6.0 | MIT | https://github.com/jridgewell/sourcemaps | runtime (bundled) |
| @jridgewell/trace-mapping | 0.3.31 | MIT | https://github.com/jridgewell/sourcemaps | runtime (bundled) |
| @jridgewell/resolve-uri | 3.1.2 | MIT | https://github.com/jridgewell/resolve-uri | runtime (bundled) |
| @sveltejs/acorn-typescript | 1.0.13 | MIT | https://github.com/sveltejs/acorn-typescript | runtime (bundled) |
| @types/estree | 1.0.10 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped | runtime (bundled) |
| acorn | 8.19.0 | MIT | https://github.com/acornjs/acorn | runtime (bundled) |
| aria-query | 5.3.1 | Apache-2.0 | https://github.com/A11yance/aria-query | runtime (bundled) |
| axobject-query | 4.1.0 | Apache-2.0 | https://github.com/A11yance/axobject-query | runtime (bundled) |
| clsx | 2.1.1 | MIT | https://github.com/lukeed/clsx | runtime (bundled) |
| devalue | 5.9.4 | MIT | https://github.com/sveltejs/devalue | runtime (bundled) |
| esm-env | 1.2.2 | MIT | https://github.com/benmccann/esm-env | runtime (bundled) |
| esrap | 2.4.0 | MIT | https://github.com/sveltejs/esrap | runtime (bundled) |
| is-reference | 3.0.3 | MIT | https://github.com/Rich-Harris/is-reference | runtime (bundled) |
| locate-character | 3.0.0 | MIT | https://gitlab.com/Rich-Harris/locate-character | runtime (bundled) |
| magic-string | 0.30.21 | MIT | https://github.com/Rich-Harris/magic-string | runtime (bundled) |
| zimmerframe | 1.1.5 | MIT | https://github.com/sveltejs/zimmerframe | runtime (bundled) |
| bits-ui | 2.20.2 | MIT | https://github.com/huntabyte/bits-ui | runtime (bundled) |
| @floating-ui/core | 1.8.0 | MIT | https://github.com/floating-ui/floating-ui | runtime (bundled) |
| @floating-ui/utils | 0.2.12 | MIT | https://github.com/floating-ui/floating-ui | runtime (bundled) |
| @floating-ui/dom | 1.8.0 | MIT | https://github.com/floating-ui/floating-ui | runtime (bundled) |
| runed | 0.35.1 | MIT | https://github.com/svecosystem/runed | runtime (bundled) |
| dequal | 2.0.3 | MIT | https://github.com/lukeed/dequal | runtime (bundled) |
| lz-string | 1.5.0 | MIT | https://github.com/pieroxy/lz-string | runtime (bundled) |
| svelte-toolbelt | 0.10.6 | MIT | https://github.com/huntabyte/svelte-toolbelt | runtime (bundled) - package.json has no license field; LICENSE file is MIT |
| style-to-object | 1.0.14 | MIT | https://github.com/remarkablemark/style-to-object | runtime (bundled) |
| inline-style-parser | 0.2.7 | MIT | https://github.com/remarkablemark/inline-style-parser | runtime (bundled) |
| tabbable | 6.5.1 | MIT | https://github.com/focus-trap/tabbable | runtime (bundled) |
| @lucide/svelte | 1.57.0 | ISC | https://github.com/lucide-icons/lucide | runtime (bundled), icons; notice in `LICENSES/ISC-lucide.txt` |
| tailwind-merge | 3.7.0 | MIT | https://github.com/dcastil/tailwind-merge | runtime (bundled) |

Notices: `LICENSES/MIT.txt` (MIT), `LICENSES/Apache-2.0.txt` (aria-query,
axobject-query: Apache-2.0; copyright of these two is held by the A11yance
authors, see their repositories).

## 4. PWA - build/test tooling (not distributed)

273 packages from `package-lock.json` that are not part of the bundle
(build, lint, test). They are not redistributed with the product; licenses
shown for completeness. Direct tools: @axe-core/playwright@4.14.0, @eslint/js@9.39.5, @playwright/test@1.64.1, @sveltejs/vite-plugin-svelte@7.3.1, @tailwindcss/vite@4.3.3, @testing-library/svelte@5.4.2, @types/node@26.6.6, eslint@9.39.5, eslint-config-prettier@10.1.8, eslint-plugin-svelte@3.23.1, globals@17.13.0, jsdom@30.1.3, prettier@3.9.10, prettier-plugin-svelte@4.1.1, svelte-check@4.7.7, tailwindcss@4.3.3, typescript@5.9.3, typescript-eslint@8.72.1, vite@8.3.5, vitest@5.0.5.

| License | Count | Note |
|---------|-------|------|
| MIT | 197 |  |
| MPL-2.0 | 26 | axe-core (test), lightningcss + platform binaries (build); unmodified, not distributed |
| Apache-2.0 | 22 |  |
| ISC | 10 |  |
| BSD-2-Clause | 8 |  |
| BSD-3-Clause | 3 |  |
| MIT-0 | 2 |  |
| BlueOak-1.0.0 | 2 |  |
| Python-2.0 | 1 | argparse |
| CC0-1.0 | 1 | mdn-data |
| 0BSD | 1 |  |

The complete machine-readable list (name, version, license, repository) can be
regenerated with the method in `docs/handoffs/Lizenzinventar.md`.

## 5. PHP SDK

`sdk/php/composer.json`: license AGPL-3.0-only; `require` only `php >= 8.2` and
the extensions `ext-sodium`, `ext-curl`, `ext-json`, `ext-mbstring` (part of
PHP, license PHP-3.01 / system libs; not distributed by this repository). No
Composer packages, so no third-party code is bundled.

## 6. Fonts, icons, assets

| Asset | Path | License | Source | Use | Notice |
|-------|------|---------|--------|-----|--------|
| App icons | `pwa/public/icon.svg`, `icon-192.png`, `icon-512.png`, `icon-maskable-512.png` | project-owned (assumed; simple rounded square + 3 bars) | - | runtime | none |
| Docs site icon | `site/assets/icon.svg` | same as above | - | runtime (docs site) | none |
| Docs site CSS/JS | `site/assets/site.css`, `site.js`, `theme-init.js` | project-owned | - | runtime | none |

The docs site (`site/`) loads no external fonts, scripts or stylesheets
(enforced by `site/check.mjs`); it uses the system font stack. UI components in
`pwa/src/lib/components/ui` are derived from shadcn-svelte (MIT, see
`pwa/SHADCN-LICENSE.md`).

## 7. Agent roles (VoltAgent)

| Files | License | Source | Use | Notice |
|-------|---------|--------|-----|--------|
| `.claude/agents/vg-accessibility-tester.md`, `vg-frontend-developer.md`, `vg-ui-designer.md`, `vg-ui-ux-tester.md` | MIT | https://github.com/VoltAgent/awesome-claude-code-subagents | development tooling (not shipped) | Copyright (c) 2025 VoltAgent; `LICENSES/VoltAgent-awesome-claude-code-subagents-MIT.txt` |

Files are adapted (German project header added); the MIT notice must stay with
copies and modified versions.

## 8. Out of scope

- Docker base images (`swift:6.3-noble`, `swift:6.3-noble-slim`), Ubuntu
  packages, MySQL/MariaDB, nginx, container tooling referenced from
  `deploy/`: not part of this repository's source. Anyone publishing a built
  image must add the base image's notices.
- CI actions in `.github/workflows`: not distributed.
