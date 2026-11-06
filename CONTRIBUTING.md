# Mitmachen

Danke für dein Interesse! Das Projekt ist **AGPL-3.0-only**; mit einem Beitrag erklärst du dich damit einverstanden, dass er unter dieser Lizenz veröffentlicht wird (Developer Certificate of Origin: `git commit -s`).

## Bevor du anfängst

- Lies [`AGENTS.md`](AGENTS.md) (Arbeitsregeln), [`docs/STATUS.md`](docs/STATUS.md) und die [Entscheidungen (ADR)](docs/decisions/). Größere Änderungen bitte zuerst als Issue besprechen.
- **Keine Geheimnisse, Schlüssel, Kundendaten oder echten Dumps** in Issues, Commits oder Tests. Nur synthetische Daten.
- Sicherheitslücken: [SECURITY.md](SECURITY.md), nicht als öffentliches Issue.

## Entwicklung

```sh
./backend/integration-test.sh          # Backend inkl. MariaDB (Docker); Swift 6.3
cd pwa && npm ci && npm run format && npm run lint && npm run check && npx vitest run && npx playwright test
php sdk/php/tests/sdk_test.php
node site/build.mjs && node site/check.mjs
```

Die CI (`.github/workflows/ci.yml`) muss grün sein: Backend (Linux amd64/arm64), PWA (Lint, Check, Unit, E2E mit axe), PHP-SDK (8.2–8.4), Echtläufe (`e2e-real`), Doku-Seite.

## Konventionen

- Texte der Oberfläche und Doku **deutsch**, Code, Bezeichner und Kommentare **englisch**; jede Quelldatei beginnt mit `SPDX-License-Identifier: AGPL-3.0-only`.
- Kleine, in sich geschlossene Commits; Fehlerkorrekturen mit Test. Entscheidungen mit Wirkung auf Verträge, Sicherheit oder Daten als ADR unter `docs/decisions/`.
- Barrierefreiheit (WCAG 2.2 AA) und Tastaturbedienung gehören zur Definition von „fertig“; neue Laufzeit-Abhängigkeiten nur mit Begründung und AGPL-kompatibler Lizenz.
- Keine Änderung an Autorisierung, Kryptografie oder API-Verträgen ohne Review und aktualisierte Verträge in `contracts/`.
