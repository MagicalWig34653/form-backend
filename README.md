<div align="center">

# Formular-Backend

**Webformulare annehmen und sofort so verschlüsseln, dass nur der Kunde sie lesen kann.**
Verschlüsselt gespeicherte Einsendungen · Passkey-Anmeldung · Veröffentlichen mit Bestätigung · Docker für amd64 und arm64

[![CI](https://github.com/MagicalWig34653/form-backend/actions/workflows/ci.yml/badge.svg)](https://github.com/MagicalWig34653/form-backend/actions/workflows/ci.yml)
[![Lizenz: AGPL-3.0-only](https://img.shields.io/badge/Lizenz-AGPL--3.0--only-blue.svg)](LICENSE)
![Status: frühe Entwicklung](https://img.shields.io/badge/Status-fr%C3%BChe%20Entwicklung-orange)

[**Dokumentation**](https://magicalwig34653.github.io/form-backend/) ·
[Einrichtung](https://magicalwig34653.github.io/form-backend/einrichtung.html) ·
[Admin-API](https://magicalwig34653.github.io/form-backend/api.html) ·
[Stand & Roadmap](https://magicalwig34653.github.io/form-backend/status.html)

</div>

> **Ehrlich zum Stand:** Neubau des bisherigen PHP-Formularbackends, funktional weitgehend komplett (Eingang, Verschlüsselung im Browser, Verwaltung per PWA, Mail, Webhooks, Domains/Statistik, MCP mit OAuth, Migration aus der Altinstanz) und in CI sowie in Echtläufen gegen die echte Binary geprüft. **Es gab noch kein unabhängiges Sicherheitsaudit und keinen Produktivbetrieb:** setzen Sie es nicht mit schützenswerten Echtdaten ein, bevor ein Audit stattgefunden hat. Offene Punkte und Roadmap: [Stand & Roadmap](https://magicalwig34653.github.io/form-backend/status.html).

## Was es kann

| | |
|---|---|
| 🔐 **Verschlüsselt gespeicherte Einsendungen** | Der Server versiegelt jede Einsendung beim Eingang mit dem öffentlichen Schlüssel des Kunden (HPKE, AES-256-GCM) und speichert nur das Chiffrat. Den privaten Schlüssel hält allein der Kunde. Der Klartext liegt nur während der Anfrage im Speicher des Servers (TLS vorausgesetzt), er wird nie gespeichert oder protokolliert. |
| ✍️ **Signierter, wiederholsicherer Eingang** | Das [PHP-SDK](sdk/php/README.md) signiert jede Anfrage (Ed25519, Zeitstempel); Idempotenz über `Idempotency-Key`, keine Doppelbuchung bei Wiederholung oder paralleler Anfrage. |
| 🗝️ **Passkey + zweiter Faktor** | WebAuthn (ES256/RS256/EdDSA), danach Passwort (Argon2id). Einheitliche Fehlermeldung, Sperren, Sitzungswechsel bei jedem Schritt, CSRF- und Herkunftsprüfung. |
| ✅ **Veröffentlichen mit Bestätigung** | Entwürfe sind frei bearbeitbar; live geht nur, was ein angemeldeter Mensch für genau diesen Stand bestätigt. Versionen sind unveränderlich. |
| 🧩 **Feine Rechte** | Einzelrechte je Kunde oder Formular, bei jeder Anfrage live aus der Datenbank geprüft. Nicht sichtbare Objekte sind „nicht gefunden“. |
| ✉️ **Mails mit Inhalt** | Wie im Altsystem: Organisations- und Bestätigungsmail mit Platzhaltern, über SMTP (TLS/STARTTLS) oder den Alt-Mail-Proxy. Der Inhalt wird für die Mail nicht gespeichert; Zustand und Fehlercode je Mail sind einsehbar. |
| 🤖 **MCP für Claude & Co.** | MCP-Server mit persönlichen Tokens und OAuth 2.1 (PKCE, dynamische Registrierung); Statistikwerkzeuge ohne Klartext. |
| 🔄 **Umstieg aus der Altinstanz** | Assistent mit Quellprüfung, Trockenlauf, Test-Entschlüsselung im Browser und Delta-Import. |
| 🐳 **Betrieb mit Docker** | Ein Multi-Arch-Image (amd64 + arm64), läuft nicht als Root, liefert die Oberfläche selbst mit strenger CSP aus. |

## Schnellstart (Betrieb)

Das Backend läuft als ein Container (zwei Listener: öffentlich für SDK/MCP, intern für Oberfläche und Verwaltung) gegen eine **externe MariaDB** und hinter einem **externen Reverse Proxy** (TLS dort). Docker Swarm oder Docker Compose:

```sh
# Geheimnisse außerhalb des Repositorys erzeugen (nie einchecken)
umask 077
openssl rand -hex 32 > /geschuetzt/server.key
openssl rand -hex 24 > /geschuetzt/db_password

# Prüflauf ohne Änderungen, danach interaktives Setup (fragt Hosts, Ports, Proxy-Netze)
deploy/swarm/setup.sh --dry-run --db-password-file /geschuetzt/db_password      # oder: sudo deploy/compose/setup.sh ...
deploy/swarm/setup.sh --db-password-file /geschuetzt/db_password
```

Danach den ersten Administrator anlegen (`bootstrap-admin`), im Browser den Setup-Assistenten durchlaufen (Passkey, Wiederherstellungscode, Mail, Adressen) und optional die Daten einer Altinstanz übernehmen (Umstieg). Proxy-Beispiele: [`deploy/proxy/nginx.conf.example`](deploy/proxy/nginx.conf.example). Alle Variablen, Prüfungen, Update, Rollback und Backup/Restore: [`docs/BETRIEB.md`](docs/BETRIEB.md) und die [Einrichtungsanleitung](https://magicalwig34653.github.io/form-backend/einrichtung.html).

Image: `ghcr.io/magicalwig34653/form-backend` (amd64 + arm64).

## Schnellstart (Entwicklung)

Voraussetzungen: Swift 6.3, Docker (für MariaDB-Tests), Node 22, PHP 8.2+.

```sh
sh backend/run-tests.sh                              # Swift-Tests ohne Datenbank + PHP-Kreuztest
./backend/integration-test.sh                        # alle Backend-Tests inkl. MariaDB (Docker)
bash backend/ci-linux.sh                             # dasselbe im Linux-Container (wie die CI)
php sdk/php/tests/sdk_test.php                       # PHP-SDK-Einheitstests
cd pwa && npm ci && npm run lint && npm run check && npm test && npm run build && npx playwright test
bash backend/e2e-setup.sh                            # Echtlauf: Setup → Formular → SDK-Einsendung → Entschlüsselung im Browser
bash backend/e2e-mcp.sh                              # Echtlauf: persönliches MCP-Token und OAuth 2.1
bash backend/proxy-probe.sh                          # Image + MariaDB + nginx: Listener-Trennung
node site/build.mjs && node site/check.mjs           # Dokumentationsseite bauen und prüfen
```

Mitmachen: [CONTRIBUTING.md](CONTRIBUTING.md). Sicherheitslücken bitte nicht öffentlich melden: [SECURITY.md](SECURITY.md).

## Aufbau

```
backend/    Swift: FormCrypto · FormCore · FormPersistence · FormHTTP · FormIngest · FormAuth · FormAdmin · App
            db/ (Schema, Prüfungen) · Dockerfile · Skripte für Tests
pwa/        Svelte-Oberfläche (Anmeldung, Verwaltung, Einsendungen lesen) mit Unit-, Browser- und Barrierefreiheitstests
contracts/  Verträge: Eingang, Krypto, Daten, Abläufe, Rechte (OpenAPI, JSON-Schema, Markdown)
sdk/php/    PHP-SDK (signiert und sendet Einsendungen) und Kreuztests der Krypto-Bibliothek
deploy/     Docker Swarm und Compose (Setup-/Update-Skripte), Beispiel für den Reverse Proxy
site/       Quelle der Dokumentationsseite (GitHub Pages)
docs/       Anforderungen, Entscheidungen (ADR), Übergaben, Paritätsmatrix zum Altsystem
```

## Dokumentation

Alle Anleitungen und Referenzen: **<https://magicalwig34653.github.io/form-backend/>**

Für Mitwirkende und Agenten: [`AGENTS.md`](AGENTS.md) → [`docs/STATUS.md`](docs/STATUS.md) → [`docs/FORTSETZUNG.md`](docs/FORTSETZUNG.md). Das Repository ist die einzige Quelle der Wahrheit; der aktuelle Stand mit Prüfergebnissen und die nächsten Schritte stehen dort.

## Lizenz

GNU Affero General Public License v3, nur diese Version – **AGPL-3.0-only**. Siehe [LICENSE](LICENSE). Lizenzen eingebundener Komponenten: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
