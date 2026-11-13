# Veröffentlichung des Repositories (Vorbereitung)

Stand 06.11.2026. Das Repository ist privat (`MagicalWig34653/form-backend`, AGPL-3.0-only); die Doku-Seite ist bereits öffentlich (GitHub Pages). **Nichts hier wurde veröffentlicht.** Die Umschaltung ist ein Schritt des Eigentümers.

## Befund der Prüfung

- **Geheimnisse:** `gitleaks` über die gesamte Historie (163 Commits) findet nur synthetische Testwerte (RFC-9180-Vektoren, erzeugte Test-Schlüssel); diese sind in `.gitleaks.toml` erlaubt, der CI-Job `secret-scan` prüft künftig jeden Push. Keine echten Schlüssel, Passwörter, Tokens oder Dumps.
- **Kundendaten:** Der echte Alt-Dump liegt nicht im Repository (nur Pfad-Hinweis in `backend/e2e-migration.sh`). In `docs/paritaet/` stehen aber echte Produktiv-Formular-IDs und Kundennamen der Altinstanz (Handlernamen) sowie lokale Dateipfade des Entwicklerrechners in `docs/handoffs/`, `docs/STATUS.md`, `contracts/`. Das steht **auch in der Git-Historie**.
- **Interna:** `.todolino.json` (Projekt-ID), `AGENTS.md`/`CLAUDE.md` (Arbeitsregeln mit Agents, Todolino), `.claude/agents/` (Rollen, darunter MIT-Material aus VoltAgent), viele Übergaben mit Arbeitsverzeichnissen.
- **Lizenzen:** `LICENSE` (AGPL-3.0-only), SPDX-Kopf in allen Quelldateien; `THIRD-PARTY-NOTICES.md` (Inventar der Abhängigkeiten) siehe `docs/handoffs/Lizenzinventar.md`.

## Entscheidung des Eigentümers (06.11.2026)

- **Neues öffentliches Repository** (nur ein Commit, ohne Historie) wird die **aktive Entwicklungs- und CI-Quelle**: öffentliche Repos haben kostenlose Actions-Minuten (im privaten Repo sind die 2000–3000 Freiminuten bereits verbraucht). Das bisherige private Repo wird **Archiv** (Historie, Todolino-Bezug) und läuft nicht mehr in der CI.
- Weggelassen werden: Altsystem-Analyse (`docs/paritaet`), interne Übergaben (`docs/handoffs`), Agent-Rollen (`.claude/agents`). `AGENTS.md`/`CLAUDE.md` bleiben.
- Export-Aufruf: `scripts/prepare-public.sh ../form-backend-public --drop-paritaet --drop-handoffs --drop-agents`
- Offen: Repository-Name/Organisation. Die Umschaltung (Anlegen, Push, Archivieren des alten Repos) erfolgt erst nach ausdrücklicher Freigabe.

## Empfohlener Weg: bereinigter Export ohne Historie

Die Historie enthält die Altdaten-Hinweise und ist für Außenstehende wertlos (204 Arbeits-Commits). Darum **nicht** das vorhandene Repo auf „public“ stellen, sondern einen bereinigten Einzel-Commit-Export in ein **neues öffentliches Repository** pushen. Das private Repo bleibt die Arbeitsquelle (CI, Pages, Todolino).

```sh
# 1. Export erzeugen und prüfen (ändert nichts am Arbeits-Repo, pusht nichts)
scripts/prepare-public.sh ../form-backend-public            # Optionen: --drop-paritaet --drop-handoffs --drop-agents --keep-todolino
# Ergebnis: ein Commit, Pfade neutralisiert, Kundenbezeichner ersetzt, gitleaks + Denylist (scripts/public-denylist.txt) grün
```

Optionen nach Bedarf: `--drop-paritaet` entfernt die gesamte Altsystem-Analyse (empfohlen, wenn Außenstehende sie nicht sehen sollen), `--drop-handoffs` die internen Übergaben, `--drop-agents` die Agent-Rollen unter `.claude/`.

```sh
# 2. Neues öffentliches Repository anlegen (Name/Organisation festlegen), dann pushen
cd ../form-backend-public
gh repo create <OWNER>/form-backend --public --source . --description "Formular-Backend: Einsendungen beim Eingang verschlüsseln (Swift/Vapor, Svelte-PWA, PHP-SDK), AGPL-3.0-only" --push
```

Alternative (nicht empfohlen): im privaten Repo Historie mit `git filter-repo` bereinigen und das Repo auf „public“ stellen — dann bleiben Issues/Actions-Historie des alten Repos, aber das Risiko übersehener Spuren ist größer.

## Nach dem Anlegen im neuen Repository (Einstellungen)

- [ ] **Security → Private vulnerability reporting** aktivieren (Verweis in `SECURITY.md`).
- [ ] **Branch protection** für `main`: PR-Pflicht, CI-Jobs (Backend Linux amd64/arm64, PWA, SDK, e2e-real, secret-scan) als Pflicht.
- [ ] **Actions:** Workflows einmal laufen lassen; `GITHUB_TOKEN` darf Packages schreiben (Image-Job). Keine Repository-Secrets nötig.
- [ ] **GitHub Pages** (Quelle: GitHub Actions); URLs in README, `site/`, `SECURITY.md`, Issue-Config auf den neuen Namen prüfen (`MagicalWig34653/form-backend`, `magicalwig34653.github.io/form-backend`).
- [ ] **GHCR-Paket** `ghcr.io/<owner>/form-backend` auf „public“ stellen (Package settings → Visibility), sonst bleibt der Pull anmeldepflichtig; README nennt das Image.
- [ ] **Dependabot** (Konfiguration liegt unter `.github/dependabot.yml`) und **Dependency graph** aktivieren; optional Secret scanning + Push protection.
- [ ] Topics/Beschreibung setzen (z. B. `swift`, `vapor`, `svelte`, `e2ee`, `hpke`, `webauthn`, `mcp`), About-Link auf die Doku-Seite.
- [ ] Erstes Release/Tag mit Hinweis „frühe Entwicklung, kein unabhängiges Audit“.

## Vor der Veröffentlichung entscheiden

1. Name/Organisation des öffentlichen Repos und ob das alte Repo privat weiterläuft.
2. Altsystem-Analyse (`docs/paritaet/`) und Übergaben (`docs/handoffs/`) mitveröffentlichen oder weglassen.
3. Agent-Rollen und `AGENTS.md`/`CLAUDE.md` mitveröffentlichen (sie zeigen die Arbeitsweise, enthalten aber Todolino-Bezug).
4. Ob vorher ein externes Sicherheitsaudit gewünscht ist (Hinweis „noch kein Audit“ steht in README und `SECURITY.md`).
5. Markenfragen: „Kubus“ steckt in Protokollkonstanten (`KUBUS-V2`, `KUBUS-AEAD:2`, `X-Kubus-*`) und im Altsystem; Umbenennung wäre ein Protokollbruch und ist nicht vorgesehen.

## Prüfen nach dem Push

- CI im neuen Repository vollständig grün (inklusive `secret-scan`).
- Stichprobe: `git log` hat genau einen Commit; Suche nach Namen, Pfaden, Hostnamen, E-Mail-Adressen im Web-UI.
- Doku-Seite und Image-Pull in einer frischen Umgebung ausprobieren (`docker pull`, README-Schnellstart).
