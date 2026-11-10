# Tatsächlicher Stand

## PWA: Fable-Umsetzung (10.11.2026, Worktree-Branch `worktree-agent-ac52228a6ed7925b5`, lokal committet, ungemergt)

Nutzerentscheidung: Struktur und Bedienung des Fable-Konzepts (Fable 5.2 vorrangig) werden in der echten PWA umgesetzt; die Demo-Optik wird nicht übernommen (shadcn-Tokens, Türkis-Akzent bleiben). Beibehalten: Bereichsauswahl (Gesamt/Kunde/Formular), Schlüsselstatus-Chip, Passkey-Direktabfrage bei frischer Anmeldung, Zero-Knowledge-Regeln (nichts im Dashboard entschlüsseln, „—“ statt Nullen). URLs bleiben unverändert (`/overview`, `/t/:id`, `/t/:id/f/:id/<tab>`); neu nur `/forms`.

Lückenliste (Ist-Stand vor der Umsetzung):

- Navigation: Gruppen „Arbeitsbereich/Verwaltung“ mischten Bereich, Verzeichnisse und Systemseiten; keine Formularübersicht über alle Kunden; Systemseiten (Einstellungen, Einrichtung, Umstieg, Verbindungen) für alle sichtbar; Mitglieder als Seitenleisten-Eintrag statt am Kunden.
- Shell: mobile Navigation als selbstgebaute Schublade statt Sheet; Suche nur in der Seitenleiste; kein Offline-Hinweis; Aktiv-Markierung ohne Akzentbalken.
- Seitenaufbau: Formular-Reiter uneinheitlich (fünf „Pillen“, dahinter Unterreiter und Schaltflächen ohne eigene Adresse); kein gemeinsamer Seitenkopf mit Bereichsangabe und Reitern; Kunde ohne Reiter; Karten teils verschachtelt (Bearbeiten-Formular und Vorschau im Feld-Panel).
- Bestätigungen: native `confirm()`-Dialoge an acht Stellen, uneinheitlich und nicht zugänglich gestaltbar.
- Zustände/Tabellen: Fehler je Quelle weitgehend vorhanden; Tabellen ohne Sortier-/Zeilenregeln des Konzepts; Einsendungen ohne einheitliche Massenleiste.
- Feldeditor: nur Auf/Ab-Schaltflächen, keine Live-Ansage, keine Tastaturgriffe, keine Positionsnummern.
- Befehlspalette vorhanden; es fehlen Kürzel für die Bereichsauswahl und Aktionen wie Schlüssel entsperren.
- Konsistenz: gemischte Schaltflächen-/Hinweisformen, vereinzelt „Wollen Sie“-Formulierungen.

Fortschritt je Stufe:

- Stufe 1+2 (Fundament, Navigation, Seitenaufbau; ein Commit): Navigation in Bereich (Übersicht, Einsendungen, Statistik) / Verwalten (Kunden, Formulare, Tokens) / System (nur Systemadministration, Betrieb auch für Berechtigte) und Fuß (Konto, Hilfe, Abmelden); neue Route `/forms` (Formularverzeichnis über alle Kunden, Status Entwurf/Live/Pausiert, entfernbarer Kundenfilter `?kunde=`); Suche und Offline-Chip in der Kopfzeile; mobiles Menü als Sheet (Fokus auf dem ersten Eintrag, Escape, Fokusrückgabe); gemeinsamer Bestätigungsdialog (`lib/confirm.svelte.ts`, `ConfirmHost`, ui/alert-dialog) ersetzt alle nativen `confirm()`; Router-Guard (`router.setGuard`) fragt vor dem Verlassen mit ungespeicherten Änderungen genau einmal; Formular mit neun Reitern in Arbeitsreihenfolge (Übersicht, Felder, Ablauf, Einsendungen, Mail, Webhooks, Aufbewahrung, Einbindung, Veröffentlichen), jeder mit eigener Adresse; Kunde mit Reitern Formulare/Mitglieder; `PageHeader` mit Reiterbereich, `PageTabs`, `CustomerHeader`; Dialoge docken mobil unten an.
- Geprüft: svelte-check 0, eslint, prettier, vitest (232), Playwright komplett (147 bestanden, 9 übersprungen wie zuvor).
- Stufe 3 (Feldeditor, Palette): Positionsnummern, Alt+Pfeil verschiebt die Zeile direkt, Live-Ansage „Feld, Position n von m“, Fokus bleibt in der Zeile; Palette mit „Mitglieder“ (Kundenbereich) und „Schlüssel entsperren“, Kürzel G dann B öffnet die Bereichsauswahl. Geprüft: Playwright 149 bestanden, vitest 232, check/lint grün.
- Bewusst NICHT umgesetzt: Greifmodus (Leertaste/Pfeile/Esc) und Zeigerziehen im Feldeditor (jede Verschiebung wird sofort am Entwurf gespeichert, ein Abbruch-Zustand fehlt); Zwei-Spalten-Editor mit Eigenschaftenbereich; Passkey-Bestätigung im Bestätigungsdialog (nur serverseitig erzwungene frische Anmeldung bleibt); Sortierung/Seitenwechsel/Filter-in-URL der Tabellen außer `/forms?kunde=`; Veröffentlichen-Punktindikator und Versionsvergleich (keine Vergleichsdaten); gemeinsamer Entsperrdialog (Chip führt weiter zum Konto); Offline: schreibende Aktionen nicht deaktiviert; Sitzungsablauf-Dialog; Massenleiste weiterhin oben statt unten.

## PWA: Bereichsauswahl (10.11.2026, Worktree-Branch `worktree-agent-a9782b02214d315f9`, lokal committet, ungemergt)

- Neu oben in der Seitenleiste: Auswahlfeld „Bereich“ (Gesamt, je Kunde Gruppe mit Kunde und Formularen; Combobox/Listbox, Tastatur, Escape gibt Fokus zurück, Suchfeld ab 8 Einträgen). Der Bereich ergibt sich nur aus der Route (`lib/area.ts`, `areaOf`); Auswahl navigiert. Neue Route `/overview` (Gesamt-Dashboard, auch Startseite nach Anmeldung), `/t` bleibt die Kundenliste („Kunden“).
- „Einsendungen“/„Statistik“ folgen dem Bereich (Gesamt: `/overview#recent-entries|statistics`, Kunde: `/t/:id#…`, Formular wie bisher); „zuletzt geöffnet“-Logik und `?need=`-Hinweise der Seitenleiste entfallen. Gesamt-Dashboard: `OverviewLoader.loadMany` (MAX_PARALLEL gilt kundenübergreifend), `TenantOverview` ohne Einrichtungsfortschritt, Fehler je Kunde/Formular einzeln, keine Nullen für fehlende Daten. Formularlisten: `lib/formLists.svelte.ts` (lazy, 60 s Cache, 4 parallel).
- Geprüft: svelte-check 0, eslint, prettier, vitest (226), Playwright komplett grün (u. a. neue `e2e/area.spec.ts`, angepasste `e2e/sidebar.spec.ts`). Offen: visuelle Abnahme; `/overview` lädt bei sehr vielen Formularen je Formular 3 Anfragen (nur erste 100 Formulare je Kunde).

## PWA-Darstellung nach thermoctl-Design (08.11.2026, Worktree-Branch `worktree-agent-a5d896957ca92f3cf`, ungemergt)

- Darstellungsschicht (Tokens, Stile, UI-Bausteine, Shell, Seitenköpfe, Karten, Dashboard) von Grund auf nach thermoctl neu gebaut; Logik, API, Router, Stores, Krypto, Berechtigungen, i18n und `data-testid` unverändert. Akzent: 20 Farben mit berechnetem Kontrast, Glow in 6 Stufen (Standard aus), Darstellung-Dialog. Menüeinträge sind nie tot (Hinweis `?need=` + Fokus auf die Liste), Leerzustand „Ersten Kunden anlegen“, Systemadministrator sichtbar.
- Geprüft: lint, svelte-check, vitest (214), Playwright inkl. axe (136 bestanden), `scripts/contrast.mjs` (alle 20 Akzente), `npm audit --omit=dev` sauber. Stack und `package.json` unverändert.
- Übergabe, Seiten vorher/nachher, offene Punkte, Screenshots: `docs/handoffs/UI-thermoctl-Angleichung.md`, `docs/ux/bilder-neu/`. Nächster Schritt: visuelle Abnahme durch den Nutzer; Dateibesitz frei, keine laufenden Jobs.

## Setup-Menü (07.11.2026)

- `deploy/{swarm,compose}/setup.sh` (interaktiv, Terminal, whiptail/dialog, noch keine Env-Datei): Hauptmenü statt Einzelfenster, Logik gemeinsam in `deploy/swarm/lib.sh` (`setup_menu`, `field_label`, `finalize_config`). Felder mit `field_ok`-Prüfung, RP-ID folgt dem Origin bis zur manuellen Änderung, DB-Passwort per passwordbox nur als Variable/Secret-Datei (nie Env-Datei, nie angezeigt). „Trockenlauf anzeigen“, „Jetzt installieren“ (blockiert bei ungültigem Feld, Platzhalter example.org/.com oder fehlendem Passwort, dann Bestätigung), Abbrechen ohne Änderung. „Verbindung prüfen“ bewusst weggelassen (Swarm-Check legt Dienste an, Seiteneffekte). Zeilenabfrage unverändert (kein Terminal, kein Dialogprogramm, `FORM_PLAIN_PROMPT=1`, `--non-interactive`, `--dry-run`).
- Fund: `dialog_tool` prüfte `-t 1` innerhalb von `$(...)`, dort nie ein Terminal; der bisherige Dialogpfad von `ask` war damit tot. Terminalprüfung jetzt einmal beim Laden von lib.sh.
- Tests: `scripts/check-deploy.py` mit Pseudo-Terminal und whiptail-Double (Abbruch, Blockade, abgelehnte Eingabe, Trockenlauf, voller Swarm-Lauf mit Doubles inkl. Passwort nur in Secret-Datei, Compose-Trockenlauf). Echtes whiptail wurde nicht interaktiv bedient.

## settings.sh für Compose/Swarm (06.11.2026, lokal committet, nicht gepusht)

- Gebaut: `deploy/swarm/settings.sh` (gemeinsame Logik, Menü per whiptail oder CLI `--list/--get/--set/--unset/--check/--env`), dünner Wrapper `deploy/compose/settings.sh` (`SETTINGS_MODE=compose`). Bash 4.4+ nötig (macOS 3.2 bricht mit Meldung ab), whiptail optional. Speichern atomar, 0600, Sicherung `<Datei>.bak.JJJJMMTT-HHMMSS`; Geheimnisse (DB-Passwort, Server-Key, Bootstrap-Passwort) nie angezeigt oder geschrieben; Rollout nur über „Jetzt anwenden“ (ruft `update.sh`). `--check` ruft zusätzlich die Validierung aus `lib.sh` (dieselbe wie `update.sh`).
- Tabellen: `deploy/swarm/config-registry.tsv` (aus `SettingsRegistry.entries` erzeugt, nur Einträge mit ENV-Name; Test `SettingsRegistryTSVTests`, neu erzeugen mit `UPDATE_CONFIG_TSV=1 swift test --filter SettingsRegistryTSVTests`) und handgepflegte `config-extra.tsv` (Deploy-Variablen). `KEY_FILE`-Varianten werden aus der Vorlage abgeleitet. Default einer in der Vorlage aktiven Variablen ist der Vorlagenwert.
- Eingebunden: Allowlist in `.github/workflows/deploy-branch.yml`, `deploy/branch/README.md`, `site/content/einrichtung.html` (Seite gebaut, `site/check.mjs` ok).
- Geprüft: `bash -n`, shellcheck; `SettingsRegistryTSVTests` (4 Tests); `scripts/check-deploy.py` erweitert um Tabellenkonsistenz gegen beide Vorlagen und settings.sh-Fälle (CLI, Ablehnung, Backup, Secret-Schutz, Idempotenz, 0600, Menü mit whiptail-Double). Lauf in Debian-Container (Bash 5.2, ohne Docker-Daemon); auf dem macOS-Host fehlt Bash 4.4, dort überspringt der Test die Ausführung (nur Tabellenkonsistenz).
- Offen: echtes whiptail wurde nicht interaktiv bedient (nur Double); `update.sh` aus dem Menü nur als Trockenlauf getestet; Bash 4.4 (Untergrenze) nicht separat getestet, nur 5.2. Die Sicherung einer Datei mit entferntem Geheimnis enthält das Geheimnis weiter (0600), Hinweis an den Betreiber.

## Restlücken 3/12/13/14 (06.11.2026)

- FA-136/148: `MigrationRunner.missingTables` (Tabellenabgleich, nur lesend), `migrate` schlägt bei fehlenden Tabellen fehl; Spalten werden nicht verglichen; `/ready` unverändert. Test: geänderte Prüfsumme -> `checksumMismatch`, fehlende Tabelle erkannt.
- FA-135: `OpsMaintenance.purgeAbuse` (abgelaufene Sperren, veraltete Zähler) im Ops-Scheduler-Takt und in `ops/cleanup`.
- FA-141: Test mit synthetischen Geheimwerten (Konfiguration, Abuse-Secret, Second-Factor-Fehler, Token/Key, Ingest) gegen Antworten und abgefangene Logs.
- FA-146: nur dokumentiert. Es gibt keine Audit-Lese-API (`audit_events` wird nur geschrieben, Kategorie `key` existiert), daher keine PWA-Ansicht; nächster Schritt wäre ein `GET audit?category=` mit `audit.read`.
- Tests: `HardeningTests` (3), Gesamtsuite 426 Tests, 0 Fehler, 5 übersprungen. Branch worktree-agent-a954f20980afc4606.
## FA-015 Ingest-Budget und FA-021 Aktivschalter (06.11.2026, Worktree-Branch, ungemergt)
- Ingest: Budget je (Formular, Client-IP) über `ThrottleService.consume` (HMAC), Setting `ingest.requestsPerMinute` (60, 0 = aus), 429 `ingest_rate_limited` mit Retry-After; SDK behandelt es als vom Aufrufer wiederholbar. FormIngest hängt jetzt von FormAuth ab. Deploy-ENV `FORM_INGEST_REQUESTS_PER_MINUTE` in Compose/Swarm/Entrypoint/Beispielen ergänzt.
- Aktivschalter `PUT .../forms/{f}/active` (Recht `release.publish`, Audit), PWA `ActiveSwitch.svelte` im Überblick. ADR 0036.
- Geprüft: gesamte Swift-Suite 425 Tests, 0 Fehler (5 übersprungen); PWA lint/check/vitest (167) grün; SDK-PHP-Tests grün; `scripts/check-deploy.py` ok. Offen: `loadtest.sh` mit Budget, Doku in BETRIEB.md nur über ADR.

## Einsendungen/Export — E2E-Korrektur (03.11.2026)

Auf `fix-e2e-entries` / `form-backend-e2e2` (Basis `298b6c0`): Session-Mock
mit subjectId, Live-Zugriff/Audit-Mocks, separate Chiffratexport-UI wiederhergestellt;
Schmalbildtest auf lokale CSV-/JSON-Auswahl erweitert. Paketvertrag, Dateien,
Prüfstand und nächste Browserbefehle: `docs/handoffs/E2E-Entries-Export.md`.
Check (0 Fehler/0 Warnungen), Lint, 139 Vitest-Tests und diff --check bestanden.
Ein Codex ohne Delegation/Commits; Playwright auf Nutzerauftrag nicht ausgeführt.
Dateibesitz bei Übergabe frei, keine laufenden Jobs. Browserabnahme beim Nutzer.
## P12-B Abschlussimplementierung (03.11.2026, feature-keys2)

Konto-Recovery mit bestätigter Einmalanzeige, Nicht-PRF-Datenentsperrung und gemeinsamer
Setup-Schnittstelle umgesetzt. Automatischer Rotationsbeginn aus dauerhafter Markierung,
Empfänger-/Public-Key-Abgleich, Wiederaufnahme und kontogebundene Eigenreparatur ergänzt.
Vertrag: `contracts/crypto/konto-recovery.md`, ADR 0024; vollständige Übergabe und Grenzen:
`docs/handoffs/P12-B.md`. Additiver Upgrade 0027; Baseline unverändert, nicht produktiv ausgeführt.
PWA check 0/0, Lint, 147 Vitest-Tests und Build erfolgreich; Swift-Testbuild erfolgreich.
DB-/Swift-Tests und Playwright auf Nutzerauftrag nicht ausgeführt. Sicherheitsreview und
DB-/Browserabnahme bleiben nächster Schritt; keine vollständige Paketabnahme behauptet.
Ein Codex, keine Delegation/Commits/Deployments, Dateibesitz frei, keine laufenden Jobs.
Branch/Worktree: `feature-keys2` / `form-backend-keys2`; externer Todolino-Status unverändert.

## P12-A UI-Merge – Browsermock-Korrektur (03.11.2026)

Branch `fix-ui-seam`, Worktree `form-backend-seam`: Feldeditorselektor exakt,
Einsendungslisten-Mocks queryunabhängig und auf den vollständigen API-Pfad
begrenzt; Exportmock ebenfalls präzisiert. Log tatsächlich 3 Fehler/1 Erfolg.
Vertrag, Dateien, Ursachen, Prüfstand und Fortsetzung:
`docs/handoffs/P12-A-Seam-Fix.md`. Ein Codex, keine Delegation/Commits;
Playwright auf Nutzerauftrag nicht ausgeführt. Check (0 Fehler/0 Warnungen),
Lint, 104 Vitest-Tests und diff --check bestanden; Details im Handoff.
Dateibesitz frei, keine laufenden Jobs. Browserabnahme als nächster Schritt beim Nutzer.

> **Neue Session: zuerst `docs/FORTSETZUNG.md` lesen** (aktueller Gesamtstand, Reihenfolge, Befehle, Berechtigungen). Der Rest dieser Datei ist ein chronologisches Protokoll; die jüngsten Einträge stehen unten.

Stand: 25.10.2026.

## Vorhanden

- Zusammengeführte Anforderungen aus der Brainstorming-Session mit Unterscheidung von Beschlüssen, Vorschlägen und offenen Fragen.
- Architekturentwurf für Module, Formular-/Ablaufmodell, Kundenanbindungen, Daten/Debug/Statistik und Migration.
- Entwicklungsstruktur für Claude Code, Sonnet, Haiku und sinnvolle Codex-Nutzung.
- Claude-Agentdefinitionen und Paket-/Übergabevorlagen.
- Gemeinsames Repositorygerüst mit backend/, pwa/, sdk/php/, clients/docker/, contracts/ und docs/.

## Nicht implementiert oder geprüft

Keine Anwendung, kein Swift-Package, keine npm-Abhängigkeiten, kein API-Vertrag, kein Build/CI, keine Tests und keine Produktmigration. Keine aktuellen Produktionsdaten oder realen Schlüssel geprüft. Kein Remote, kein Commit, kein Deployment.

Die Agentdefinitionen sind vorbereitet, aber nicht in Claude Code ausgeführt. Modellaliase/Toolzugriff hängen von dessen Umgebung ab. Kein Codex-Plugin installiert oder konfiguriert.

## Erster nächster Schritt

P0: aktuelle Funktions-, Daten- und Kompatibilitätsmatrix aus dem Altprojekt erheben. Anschließend P1/P2 entscheiden und technische Risiken im kleinen Durchstich prüfen. Siehe ARBEITSPLAN.md.

## Aktuell (26.10.2026, nach P0)

P0 inhaltlich abgeschlossen: A–D plus Reviews A, C, D liegen unter `docs/paritaet/`, Zusammenführung in `docs/PARITAET.md`. Offen: Review zu B, Einarbeitung der Review-Korrekturen in A/C/D. Keine laufenden Jobs. Codex-Aufträge liefen mit `--model gpt-6.1-sol` ohne Fehler (Modell in der Ausgabe nicht bestätigt). Beschlossen (ADR `decisions/0001-grundentscheidungen-p1.md`): Vapor+Fluent, Mandantenmodell Kunde>Formulare mit Rollen Admin/Betreuer/Kunde, Altchiffrate nur im Migrationswerkzeug lesen, Code englisch/Nutzertexte deutsch. Review B konnte nicht gestartet werden (Auto-Mode-Classifier lehnte den Codex-Auftrag zweimal ab, trotz Nutzerfreigabe; nicht umgangen). Nächster Schritt: restliche P1-Entscheidungen (Nr. 4 Rest, 5–13, 15, 16, 18, 19) mit dem Nutzer treffen (blockiert jede Implementierung, `AGENTS.md` verbietet Raten). Die Tabelle unten ist der ältere Zwischenstand; B und C sind inzwischen erstellt.

Berechtigungen (27.10.2026): Codex-Delegation scheiterte am Auto-Mode-Classifier („Data Exfiltration"). Ursache war nicht `permissions.allow`, sondern fehlende Einträge in `autoMode.allow` und `autoMode.environment` in `~/.claude/settings.json` (nicht im Repo). Dort ergänzt: Codex als vertrauenswürdiger Dienst, Lesezugriff auf Alt- und Neuprojekt, `secrets/` und `keys/secrets.ini` ausgeschlossen. Danach wurde der Reviewauftrag angenommen. Bei neuer Maschine/Session diese Einträge erneut setzen. Laufender Job: Codex-Task für `docs/paritaet/review-P2-vertraege.md`.

P2 ABGESCHLOSSEN als Entwurf (26.10.2026): Verträge liegen unter `contracts/{ingest,crypto,data,flow,auth}/` (je mit HANDOFF/README), Review B unter `docs/paritaet/review-B.md`. Mitgelieferte Prüfungen: `flow/validate.py` (12 Schemas, 21 Beispiele, 41 Negativfälle OK), `auth/validate.py` (66 Operationen, 29 Payloadfälle OK; kein vollständiger OpenAPI-Validator), ingest YAML gültig laut Agent. Keine Laufzeit-, DB- oder Krypto-Tests. KEIN unabhängiges Vertragsreview: Codex- und Claude-Reviewer-Aufträge wurden vom Auto-Mode-Classifier abgelehnt (nicht umgangen). Offen: Review-Korrekturen aus review-A/C/D/B in die Teilberichte einarbeiten; Nutzerentscheidungen Nr. 20–22 (siehe OFFENE-ENTSCHEIDUNGEN). Keine laufenden Jobs. Nächster Schritt: Vertragsreview (nach Freigabe), dann P3 (Durchstich; Swift-Toolchain-Verfügbarkeit prüfen).

P2-Update: P2-1 Ingest fertig (`contracts/ingest/`, ungeprüft; offen: Adapter für Alt-SDK-Header-Schlüssel vs. ADR 0001). P2-2 Krypto, P2-3 Daten, P2-5 Auth nach erneuter Freigabe gestartet (Codex, schreiben nur `contracts/crypto|data|auth/`). Danach: Verträge gegenlesen, unabhängiges Review, Vertragskonsistenz, dann P3.

P2 läuft (26.10.2026, Codex `gpt-6.1-sol`, je Paket eigenes Verzeichnis unter `contracts/`): P2-1 Ingest (`contracts/ingest/`) und P2-4 Flow (`contracts/flow/`, Job `task-mvppwm3z-v1vvua`) gestartet; Review B (`task-mvpmvnl1-b5lqpa`) läuft noch. NICHT gestartet (Auto-Mode-Classifier lehnte ab): P2-2 Krypto (`contracts/crypto/`), P2-3 Datenmodell (`contracts/data/`), P2-5 Rechte/API (`contracts/auth/`). Prompts sind aus ARBEITSPLAN P2 und ADR 0001–0003 rekonstruierbar. Status der Jobs: `node ~/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs status`.

Update 2: Alle Grundentscheidungen P1 beschlossen (ADR 0003 `produkt-und-betrieb`). Nächster Schritt: P2 (Verträge, Detailwerte, Targetstruktur, Architekturentwurf schärfen) und danach P3 (Durchstich). Weiterhin keine Implementierung, kein Commit.

Update: ADR `0002-sicherheit-und-cutover.md` beschlossen (Nr. 15, 16, 18, 19). Laufender Job: Codex-Task `task-mvpmvnl1-b5lqpa` (Review B, schreibt nur `docs/paritaet/review-B.md`; Status per `codex-companion.mjs status`). Offen für P1: Nr. 4 (Rest), 5–13, Schwellenwerte.

## P0-Fortschritt (Stand 26.10.2026)

Altprojekt (nur lesend): `<workspace>/form-backend_bvk`. Teilberichte unter `docs/paritaet/`:

| Teil | Datei | Status |
| --- | --- | --- |
| A Routen/Handler | `A-routen-handler.md` | erstellt, ungeprüft (nur Agent-Bericht, keine Stichprobe) |
| B Funktionen/Felder | `B-funktionen-felder.md` | NICHT erstellt; Sonnet-Agent und Codex-Delegation (gpt-6.1-sol) wurden vom Auto-Mode-Classifier abgelehnt (Data Exfiltration: Altprojekt liegt außerhalb des Arbeitsverzeichnisses, Codex sendet Code an externen Dienst). Wartet auf Nutzerfreigabe |
| C Daten/Migration | `C-daten-migration.md` | erstellt durch Koordination (26.10.2026) aus Schema/Migrationen; nur Spaltenebene, `migrate.php`/`verify.php` nicht gelesen; ungeprüft |
| D Krypto/Protokolle | `D-krypto-protokolle.md` | erstellt, ungeprüft |

Wichtige Befunde (ungeprüft): Ed25519-Prüfung entfällt ohne hinterlegten Public Key; kein eigener Passwort-Login-Lockout; Rate-Limit nicht auf Admin-Seiten/health; `Crypto.php` lehnt `:2` ab entgegen Spec; MFA-Secret doppelt Base64; v1-Header-Schlüssel roh >32 Zeichen; Ed25519-Signatur hängt an `json_encode`-Kanonisierung; Doku 09 zur Idempotenz veraltet. Testvektoren: nur der RFC-9180-Vektor liegt als Datei vor.

Laufender Job (26.10.2026): Codex-Task `task-mvp8sb15-d8gbv0` (P0-B, Modell `gpt-6.1-sol`, Nutzer hat Codex-Agents ausdrücklich freigegeben). Schreibt nur `docs/paritaet/B-funktionen-felder.md`. Status prüfen mit `node ~/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs status task-mvp8sb15-d8gbv0`; Abbruch `/codex:cancel`. Fällt Codex wegen Limit aus, B mit Claude als Fallback erstellen.

Nächster Schritt: nach B Stichproben-Review von A–D (unabhängig, möglichst Codex) und Zusammenführung zu `docs/PARITAET.md`; danach P1-Entscheidungen mit dem Nutzer (OFFENE-ENTSCHEIDUNGEN Nr. 2, 3, 4, 12, 14).

## Ergänzung: verbindliches Projektgedächtnis und Lizenz

Die vollständige Dokumentation ist im Repository vorhanden. Repository als alleinige Source of Truth und wegwerfbare Sessions sind ausdrücklich verbindliche Anforderungen; AGENTS.md, CLAUDE.md und Entwicklungsablauf sind entsprechend ergänzt. Die Lizenz ist AGPLv3 (AGPL-3.0-only); der vollständige offizielle Lizenztext liegt in LICENSE. Die Desktop-Kopie ist historisch und wird nicht fortgeschrieben.

Dokumentationsänderungen wurden auf Vollständigkeit, Konsistenz der Lizenzangaben und Vorhandensein der referenzierten Dateien geprüft. Anwendungstests sind weiterhin nicht vorhanden und wurden nicht behauptet. Nächster Schritt bleibt P0; keine laufenden Jobs oder delegierten Pakete.

## Vertragsreview P2 (27.10.2026)

Unabhängiges Codex-Review (`task-mvq85yyb-onzbol`, abgeschlossen) liegt in `docs/paritaet/review-P2-vertraege.md`: 19 Befunde (0 kritisch, 11 hoch H01–H11, 7 mittel M01–M07, 1 niedrig L01). Fazit: Verträge sind noch nicht gemeinsam implementierungsreif (Identitäten, Rechte-/Sitzungspersistenz, Hostauflösung, Schlüsselgeneration vs. unveränderliche Formulardefinition, Resend/Hold). Rein statisch gelesen, nichts ausgeführt; 15 Altcode-Stichproben bestätigt. Keine laufenden Jobs.

Technisch korrigierbar ohne Nutzerentscheidung (nächster Auftrag): H01, H03, H06, H08, H10, M01, M03, M06, M07, L01, Teile von M02. Nutzerentscheidungen nötig: siehe OFFENE-ENTSCHEIDUNGEN Nr. 20–22 und 24–30. P3 (Durchstich) erst nach Korrektur der Verträge bzw. mit Beschränkung auf unabhängige Teile (Swift-Toolchain, Krypto-Testvektoren, MariaDB-Anbindung).
Laufender Job: Codex-Agent a152befd808989d3d (technische Vertragskorrekturen H01,H03,H06,H08,H10,M01,M03,M06,M07,L01; schreibt nur contracts/).
Codex-Task-ID der Vertragskorrektur: task-mvqjc97t-fqaa0i (Status: node ~/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs status task-mvqjc97t-fqaa0i).

Nutzerentscheidungen zum Vertragsreview (27.10.2026) in ADR 0004 festgehalten. Der laufende Codex-Auftrag kennt sie noch nicht; nach seinem Ende folgt eine zweite Vertragsrunde (H02 Rechtegruppen, H04, H05 Transportvertrag, H07/H09, H11 Adapter, M02 Adapter, M04, M05 Token-Übernahme).

Vertragskorrektur Runde 1 (task-mvqjc97t-fqaa0i) abgeschlossen: H01,H03,H06,H08,H10,M01,M03,M06,L01 im Entwurf behoben; M02,M07 teilweise. Validatoren vom Koordinator selbst ausgeführt: flow 12/21/46 OK, auth 66 Ops/37 Payloadfälle OK (nur statisch). Runde 2 (ADR 0004: H02,H04,H05,H07,H09,H11,M02,M04,M05) per Codex gestartet; Ergebnis noch offen und ungeprüft.
Codex-Task Vertragsrunde 2: task-mvqyvup1-9lxqr6 (Status: node ~/.claude/plugins/cache/openai-codex/codex/1.0.6/scripts/codex-companion.mjs status task-mvqyvup1-9lxqr6).
Toolchain (27.10.2026): Swift 6.4 (arm64), Docker vorhanden, PHP 8.5.9, Node 26.5; kein lokaler mariadb/mysql-Client (DB per Docker für P3 vorgesehen, ungetestet).

Vertragsrunde 2 (task-mvqyvup1-9lxqr6) abgeschlossen (28.10.2026): ADR 0004 eingearbeitet (neu: crypto/transport.md, ingest/legacy-adapter.md, flow/wiederanlauf.md, data/VALIDIERUNG.md). Validatoren vom Koordinator in venv (jsonschema, pyyaml; System-Python hat die Pakete nicht) ausgeführt: flow 12/21/51 OK, auth 76 Ops/66 Payloadfälle OK, nur statisch. Offen: Scannerentscheidung, 418/424, IP im Altstatistikbestand, Credential-Formatprüfung, Fristen (Nr. 21), Kunden-/Altschlüsselschnitt (Nr. 28). Nächster Schritt: zweites unabhängiges Vertragsreview, parallel P3 starten.

Laufende Jobs (28.10.2026, Codex gpt-6.1-sol, beide in Hintergrund gestartet, Task-IDs stehen im jeweiligen Hand-back und per codex-companion.mjs status): (1) Zweitreview der Verträge -> docs/paritaet/review-P2-vertraege-2.md; (2) P3-A Swift-Paket FormCrypto (backend/) plus PHP-Interop-Test (sdk/php/tests/), Übergabe docs/handoffs/P3-A.md. Beide Ergebnisse ungeprüft, bis ich sie ausgewertet habe.
Task-ID Zweitreview: task-mvro5tr7-scztkx.

P3-A (28.10.2026): Swift-Paket backend/ (FormCrypto: HPKE, Paket :2, kid, Kanonisierung, Ed25519) + sdk/php/tests/form_crypto.php. Vom Koordinator selbst ausgeführt (sh backend/run-tests.sh): Swift 6 Tests 0 Fehler, PHP-Interop alle PASS, beide Exit 0. Einschränkungen: Standard-'swift test' scheitert hier am Codesign (FinderInfo im Arbeitsverzeichnis), Lauf nur mit nativem (veraltetem) Builder; Float-Eingaben in der Kanonisierung abgelehnt (K13 offen); RFC-Fixture-Hash nicht neu geprüft (DNS gesperrt); Fixture aus Altprojekt kopiert; Ed25519 nicht byteweise vergleichbar (randomisiert). Übergabe: docs/handoffs/P3-A.md. Noch kein unabhängiges Review. Zweitreview der Verträge läuft (task-mvro5tr7-scztkx).

Stand 29.10.2026: Zweitreview der Verträge fertig (docs/paritaet/review-P2-vertraege-2.md): 8 von 19 Altfindings geschlossen, 11 teilweise, 8 neue Anschlussbefunde R01–R08 (4 hoch, 4 mittel); keine Implementierungsfreigabe. Laufender Job: Vertragsrunde 3 (Codex task-mvtg1c31-2i16d3, schreibt nur contracts/ und docs/handoffs/). NICHT gestartet: P3-B (MariaDB-Docker-Test) – Auto-Mode-Classifier lehnte den Codex-Auftrag ab ([Auto-Mode Bypass], vermutlich wegen Docker-Container/Image-Download); nicht umgangen, wartet auf Nutzerentscheidung. Prompt aus ARBEITSPLAN P3 und contracts/data rekonstruierbar.
P3-B (MariaDB-Docker-Test) nach Nutzerfreigabe gestartet (29.10.2026, Codex gpt-6.1-sol, schreibt nur backend/db/ und docs/handoffs/P3-B.md); Ergebnis offen. Parallel läuft Vertragsrunde 3 (task-mvtg1c31-2i16d3).

Codex-Limit (29.10.2026): Codex-Jobs task-mvtg1c31-2i16d3 (Runde 3) und P3-B scheiterten sofort: 'usage limit, try again at Nov 4th, 2026 8:13 AM'. Fallback nach Nutzervorgabe: Claude (Sonnet) startet Vertragsrunde 3 (architect) und P3-B (implementer) neu; Ergebnisse noch offen und ungeprüft. Codex ab 04.11.2026 8:13 wieder verfügbar.

P3-B (29.10.2026, Claude Sonnet, vom Koordinator nachgeprüft): backend/db/check.sh läuft auf MariaDB 12.3.3 (Docker, nur 127.0.0.1): 65 Prüfungen, 0 Fehler; Container danach entfernt; Testpasswort nur in ungetracktem backend/db/.test-secret.env. Geprüft wurde der Vertragsstand VOR Vertragsrunde 3; die Vertrags-DDL ändert sich durch Runde 3 weiter (z. B. domain_bindings.release_id/revision, transport_policy), daher nach Runde 3 check.sh gegen neues DDL wiederholen. Befunde: uq_view_host/uq_api_host sperren auch deaktivierte Hosts (falls nur aktive eindeutig sein sollen: Generated Column); Benutzername/Host case-sensitiv (Normalisierung in der Anwendung); nur 65 Stichproben, keine Nebenläufigkeits-/Fluent-Tests; Mindestversion MariaDB offen (nur 12.3.3 getestet). Details: docs/handoffs/P3-B.md. Vertragsrunde 3 (Claude architect) läuft noch.

Vertragsrunde 3 (29.10.2026, Claude architect) abgeschlossen: R01,R02,R04,R06,R07 im Entwurf behoben; R03,R05,R08 und M02–M05,M07,H05,H11 teilweise; Nutzerentscheidungen D1–D11 in docs/handoffs/vertragsrunde-3-offen.md. Vom Koordinator ausgeführt: flow-Validator 12/21/53 OK; auth-Validator 83 Ops/93 Payloadfälle OK; neues Vertrags-DDL läuft auf MariaDB 12.3.3 (Schema lädt), backend/db/check.sh nach Kopie des neuen DDL: 53 pass / 12 fail – alle 12 Fehler sind veraltete Testfixtures (neue NOT-NULL-Spalte stored_objects.payload_sha256, geänderte domain_bindings-Spalten), keine DDL-Fehler. Fixtures werden angepasst (Claude implementer).

P3-B zweiter Lauf (29.10.2026, vom Koordinator wiederholt): schema-p3.sql identisch mit contracts/data/schema-entwurf.sql; check.sh gegen MariaDB 12.3.3: RESULT pass=72 fail=0, Container entfernt. Kein unabhängiges Review. Offen: Nutzerentscheidungen D1–D11 (docs/handoffs/vertragsrunde-3-offen.md) sowie Nr. 21/28; Kryptoreview Adapter-Signaturtext; P3-C Passkey, Swift-Vapor-Fluent-Anbindung an MariaDB und End-to-End-Durchstich (Browser→Swift→DB→PHP) stehen aus.

Nutzerentscheidungen D1–D4, D6, D7 (29.10.2026) in ADR 0005 festgehalten. Folge: Verträge müssen angepasst werden (Zugriffsadress-Kopplung an Release; OAuth-Token-Übernahme entfernen, Neuanmeldung; Hinweis IP in Altstatistik). D5 offen (Nutzer wollte Erklärung), D8–D11 offen. Kryptoreview Adapter-Signaturtext offen.

Laufende Jobs (29.10.2026, Claude Sonnet): (1) Verträge an ADR 0005 anpassen (architect); (2) Kryptoreview Adapter/Transport/Digest -> docs/paritaet/review-krypto-adapter.md (reviewer). Ergebnisse offen, ungeprüft.

USAGE-LIMIT (29.10.2026): Claude-Sitzungslimit erreicht (Reset 22:30 Europe/Berlin); Codex-Limit bis 04.11.2026 08:13. Beide Agents abgebrochen: (1) Verträge an ADR 0005 anpassen (agentId ad6b2281483cb40f6, Teilstand gespeichert, ggf. unvollständige Änderungen in contracts/ – vor Weiterarbeit git-freien Diff prüfen, Validatoren neu laufen lassen); (2) Kryptoreview Adapter -> docs/paritaet/review-krypto-adapter.md (agentId a99c608a1722c3420, evtl. keine/teilweise Datei). Nächste Schritte: beide per SendMessage fortsetzen oder neu starten; danach D5, D8–D11 klären; P3-C Passkey, Vapor/Fluent-Anbindung, Durchstich.

Kryptoreview Adapter/Transport/Digest/Manifest (30.10.2026, Claude reviewer, rein statisch, ungeprüft von mir): docs/paritaet/review-krypto-adapter.md. Kernbefunde: A2 hoch (Adapter prüft ursprüngliche SDK-Signatur nicht definiert, Downgrade gegen Signaturpflicht; Altcode-Abgleich fehlt), A1/A3/T1/T2/T3/T4/D1/D2/D4/M1/M2 mittel (u.a. Idempotency-Key/Nonce fehlt im Adaptertext, Replay-Retention >=600 s, ungesalzener request_digest, Namenskollisionen, Resend-Manifest nicht an Einsendung gepinnt), Rest niedrig. Korrekturen noch nicht eingearbeitet; Vertragsagent (ADR 0005) läuft parallel.

ADR-0005-Einarbeitung (30.10.2026, Claude architect) abgeschlossen: D1 (api_host_forms mit Release-Bindung, PublishInput.rebind), D4 (Token-Übernahme entfernt, Neuanmeldung), D6, D7 (has_ip_reference, IP nur im verschlüsselten Objekt, Importvoraussetzung Bestandsprüfung) in contracts/. Vom Koordinator geprüft: flow-Validator 12/21/53 OK, auth-Validator 83 Ops/93 Payloadfälle OK, DDL lädt auf MariaDB 12.3.3, check.sh pass=70 fail=2 (nur veraltete Fixtures api_host_forms). Offen aus Agentenbericht: gilt D4 auch für handerzeugte Alt-mcp_tokens (als 'ja, nicht übernommen' gelesen – bitte bestätigen); configureApiHost liefert noch generisches Result. Laufend: Fixtures anpassen (implementer), Einarbeitung der Kryptobefunde (architect, schreibt contracts/ und docs/handoffs/vertragsrunde-4-offen.md).

P3-B dritter Lauf (30.10.2026, vom Koordinator wiederholt): schema-p3.sql identisch mit Vertrag; check.sh RESULT pass=75 fail=0. Stand gilt für DDL VOR der laufenden Kryptobefund-Einarbeitung (Agent a2809ee86021b126b); falls dieser das DDL ändert, check.sh erneut ausführen.

Vertragsrunde 4 (30.10.2026, Claude architect): Kryptobefunde A1,A3–A7,T1,T2,T4–T6,D1–D5,M1–M4 als VORGESCHLAGEN eingearbeitet (u.a. neue Tabelle adapter_replays, HMAC-Digest, Manifest-Pin). Koordinator: Validatoren flow/auth OK; Vertrags-DDL lädt auf MariaDB, check.sh pass=70 fail=5 (veraltete Fixtures ingest_idempotency; Fixture-Anpassung läuft). Hinweis: Port 33306 ist lokal belegt (Ursache nicht gefunden) -> P3B_PORT=33417 setzen. A2-FAKT (Altcode): v1-SDK sendet KEINE Ed25519-Signatur, nur Header-MACs; Adapterpfad bleibt bis zur Nutzerentscheidung nicht aktivierbar. Entscheidungsvorlage A2/T3: docs/handoffs/vertragsrunde-4-offen.md.

P3-B vierter Lauf (30.10.2026, vom Koordinator wiederholt): schema-p3.sql identisch mit Vertrag; 'P3B_PORT=33417 sh backend/db/check.sh' -> siehe Ergebnis unten. Hinweis: Port 33306 lokal belegt (Ursache unbekannt), daher P3B_PORT setzen.

Nutzerentscheidungen 30.10.2026 in ADR 0006: Adapter nicht aktivieren (SDK-Umstellung vor Cutover, Cutover-Voraussetzung für P9), Transporthülle schützt nur Anfragen, alle Alt-MCP-Tokens neu, Replay nach Löschung 409. Offen: D8–D11, Nr. 21, 28. Nächster Schritt: P4 (Vapor/Fluent-Backend, MariaDB-Anbindung, PWA-Grundgerüst) und P3-C Passkey.

Zweites Formular 30.10.2026 (ADR 0006 Nachtrag): D8 vor Ersetzen sichern, D9 Secrets verschlüsselt in DB, D11 Vorschlagswerte bestätigt, P4 starten. Offen nur noch D10 (P6-S) und Nr. 28. P4 und P3-C werden gestartet.

P4 Start (30.10.2026): P3-C Passkey-Machbarkeit (Claude architect, agentId a5267b93093256909, schreibt docs/handoffs/P3-C.md und backend/poc-passkey/) gestartet. NICHT gestartet (Auto-Mode-Classifier lehnte ab: P4-A 'Auto-Mode Bypass', P4-B 'Data Exfiltration', vermutlich wegen Paketdownloads aus SwiftPM/npm): P4-A Vapor/Fluent-Backend-Grundaufbau (backend/, ohne db/ und FormCrypto), P4-B Svelte/shadcn-PWA-Grundgerüst (pwa/). Nicht umgangen; wartet auf Nutzerfreigabe für Paketdownloads (SwiftPM, npm). Prompts aus ARBEITSPLAN P4 und diesem Stand rekonstruierbar.

Drittes Formular 30.10.2026: Nr. 28 und D10 beschlossen (ADR 0006), autoMode.allow-Regel für SwiftPM/npm-Downloads in ~/.claude/settings.json ergänzt (nicht im Repo). P4-A/P4-B werden neu gestartet.

P4-A/P4-B erneut vom Auto-Mode-Classifier abgelehnt ([Auto-Mode Bypass]) trotz ergänzter autoMode.allow-Regel; nicht umgangen. Vermutlich wirkt die Regeländerung erst nach Neustart der Session oder die Formulierung reicht nicht. Wartet auf Nutzer (/permissions oder Session-Neustart). P3-C läuft (agentId a5267b93093256909).

P3-C Passkey (30.10.2026, Claude architect, vom Koordinator nachgeprüft: backend/poc-passkey 'swift test --build-system native' 9 Tests, 0 Fehler): Altbestand speichert Credential-ID, Public Key als PEM (SPKI), signCount; Algorithmen ES256/RS256/EdDSA; Attestation verworfen. Eigene Verifikation mit swift-crypto empfohlen (webauthn-swift: nur Pre-Release, erwartet COSE statt PEM, EdDSA nicht unterstützt). Vertragslücken: passkeys-Tabelle ohne UserHandle-Spalte (UserHandle = UTF-8-Bytes des UUID-Textes; sonst bei discoverable Login Aussperrung), public_key_encoding ohne festen Wert (pem-spki), RSA <2048 Bit unbekannt. Nicht belegt: PRF/Browser, echte Authenticator-Antworten, DB-Umsetzung (nur In-Memory). Kein unabhängiges Review. Details: docs/handoffs/P3-C.md. Nutzerentscheidung nötig: Option eigene Verifikation (Empfehlung) per ADR bestätigen.
P4-A (agentId a59e4392696740fef) und P4-B (agentId a0aa47dc210715ffc) nach erneuter Nutzerfreigabe gestartet; Ergebnisse offen.

Passkey-Verifikation: eigene swift-crypto-Verifikation beschlossen (ADR 0006 Nr. 12). Offene Folgearbeit: Vertrag passkeys (user_handle, public_key_encoding), DB-Anbindung, unabhängiges Review. P4-A/P4-B laufen.

NICHT gestartet (30.10.2026, Auto-Mode-Classifier [Auto-Mode Bypass]): Vertragsergänzung passkeys (user_handle, public_key_encoding, Challenge-Tabelle; Dateibesitz contracts/data|auth, docs/handoffs/P3-C-vertrag.md). Nicht umgangen; läuft parallel zu P4-A/P4-B (Auslöser vermutlich: laufende Agenten oder DDL-Änderung am geprüften Schema). Wartet auf Nutzerfreigabe.

P4-B PWA-Grundgerüst (30.10.2026, Claude implementer, vom Koordinator nachgeprüft): in pwa/ ci/lint/svelte-check/build Exit 0, Vitest 7 Tests, Playwright 3 von 3 bestanden. Svelte 5, Vite 8, TS, Tailwind 4, bits-ui, eigener 20-Zeilen-Router (kein SvelteKit), handgeschriebener Service Worker (cached nur statische Assets derselben Origin, nie /api). npm audit: 2 low (deepmerge via vite-plugin-svelte, nur Build). Offen: /api/health ist Annahme bis P4-A, PNG-/maskable-Icons, Cache-Version manuell, kein Review/axe/CI. Details docs/handoffs/P4-B.md. Läuft noch: P4-A (a59e4392696740fef), Vertrag passkeys (a3e58b713f4fd6bea).

30.10.2026 (nach Limit-Reset): Vertrag passkeys ergänzt (Claude architect, a3e58b713f4fd6bea; user_handle, cose_algorithm, public_key_encoding pem-spki, 120-s-CHECK Challenge; auth-Validator OK, DDL noch nicht auf MariaDB geprüft). P4-A (a59e4392696740fef) wegen Limit abgebrochen und per SendMessage fortgesetzt. DB-Fixtures-Agent für Passkey-DDL gestartet.

Fixture-Agent für Passkey-DDL NICHT gestartet (Auto-Mode-Classifier, [Auto-Mode Bypass]); nicht umgangen. P4-A läuft nach SendMessage weiter.

Hinweis 30.10.2026: Mein check.sh-Lauf kollidierte mit Port 33417, vermutlich belegt durch den laufenden P4-A-Integrationstest; das Cleanup in check.sh (Container p3b-mariadb) kann dessen Container mitentfernt haben. check.sh und P4-A-Tests nicht parallel laufen lassen (gleicher Container-Name/Port); P4-A ggf. neu laufen lassen. schema-p3.sql wurde auf den neuen Vertrag kopiert, Passkey-Fixtures in check.sh fehlen noch.

P4-A Backend-Grundaufbau (30.10.2026, Claude implementer, vom Koordinator nachgeprüft): 'P3B_PORT=33417 bash backend/integration-test.sh' -> 14 Tests, 0 Fehler (FormCrypto 6, FormCore 3, FormPersistence 2, FormHTTP 3), gegen aktuelles schema-p3.sql (identisch mit Vertrag inkl. Passkey-Änderungen; Migrationsrunner wendet es auf MariaDB an). Vapor 4.122.3, Fluent 4.13.0, fluent-mysql-driver 4.8.0, swift-crypto 3.15.1 gepinnt; Targets FormCore, FormPersistence, FormHTTP, App (migrate). /health ohne DB, /ready mit SELECT 1. Grenzen: Swift-5-Sprachmodus, kein Linux-Build, TLS verify ungetestet, DDL nicht selbst idempotent (Teilschema bei Abbruch), keine Mehrdatei-Migrationen, BoringSSL-Lizenzhinweis vor Auslieferung bündeln, kein Review. check.sh-Passkey-Fixtures noch nicht angepasst (Fixture-Agent offen, wartet auf Freigabe). Details docs/handoffs/P4-A.md.

P3-B fünfter Lauf (30.10.2026, Koordinator direkt, da Fixture-Agent vom Classifier abgelehnt): check.sh pass=96 fail=0 inkl. Passkey-CHECKs (user_handle, cose_algorithm, pem-spki, 120-s-Challenge). Nicht getestet: Nicht-ASCII im user_handle. Nächste Schritte: unabhängiges Gesamtreview (Verträge + Code), P5 erstes vollständiges Formular, Passkey-Verifikation ins Backend, Migration des Altbestands (P9) vorbereiten.
Laufender Job (30.10.2026): unabhängiges Code-Review P3/P4 (Claude reviewer, agentId affc709824eff3c34) -> docs/paritaet/review-code-p3-p4.md; Ergebnis offen.

Code-Review P3/P4 (30.10.2026, Claude reviewer, rein statisch): docs/paritaet/review-code-p3-p4.md. Kein kritischer Befund; Hoch: F1 Ed25519-Strenge (Vertrag A7) nicht implementiert/getestet. Mittel: F2 GET_LOCK nicht verbindungsgebunden (Pool), F3/F4 Migration nicht wiederanlauffähig/Test prüft >40 statt 68 Tabellen, F5 Service Worker (unversionierter Cache, /admin/api nicht ausgeschlossen, kein Test), F6 Testvektoren aus eigenem PHP-Harness statt Alt-SDK, F7 RequestSignature.verify bindet Methode/Pfad/Body nicht intern. Niedrig: F8–F10. Korrektur-Agents (backend, pwa) werden gestartet.

Korrektur-Agent Backend (F1–F4, F7–F9; agentId ab37d97eedfe8030d) läuft. Korrektur-Agent PWA (F5, F10) NICHT gestartet (Auto-Mode-Classifier [Auto-Mode Bypass]); nicht umgangen, wartet auf Freigabe. Prompt aus review-code-p3-p4.md (F5, F10 PWA) rekonstruierbar.
PWA-Korrektur-Agent (F5, F10) erneut vom Classifier abgelehnt (30.10.2026) trotz /permissions; nicht umgangen. Backend-Korrektur-Agent (ab37d97eedfe8030d) läuft.
30.10.2026: Auf Nutzerwunsch weitere autoMode.allow-Regel in ~/.claude/settings.json ergänzt (Subagenten dürfen in zugewiesenen Verzeichnissen lokal bauen/testen und Docker-MariaDB-Testcontainer an 127.0.0.1 starten; kein Commit/Push, kein secrets/). Nicht im Repo; bei neuer Maschine erneut setzen.
PWA-Korrektur-Agent nach Ergänzung der autoMode.allow-Regel erneut abgelehnt ([Auto-Mode Bypass]); Regel wirkt vermutlich erst nach Neustart der Claude-Session. Nicht umgangen. Alternativ setzt der Koordinator die PWA-Korrekturen (F5, F10) direkt um.

30.10.2026 Sessionabschluss: docs/FORTSETZUNG.md angelegt (maßgeblich für die neue Session). Backend-Korrektur-Agent ab37d97eedfe8030d war beim Schreiben noch aktiv; sein Ergebnis ist unverifiziert (siehe FORTSETZUNG.md Punkt 1).

Backend-Korrektur-Agent abgeschlossen und vom Koordinator nachgeprüft (30.10.2026): run-tests.sh Exit 0 (31 Tests), integration-test.sh 31 Tests/0 Fehler, poc-passkey 11 Tests/0 Fehler. FORTSETZUNG.md aktualisiert. PWA-Korrekturen F5/F10-PWA weiter offen.

PWA-Korrekturen F5/F10-PWA (30.10.2026, Koordinator direkt, kein Agent): `pwa/public/sw.js` mit Build-Hash-Cache (Stamp per Vite-Plugin in `pwa/vite.config.ts`), Network-first für unversionierte Dateien, Cache-first nur für `/assets/*` ohne `text/html`, Deny-Präfixe (`/api`, `/admin`, `/oauth`, `/mcp`, `/health`, `/ready`), `waitUntil` für `put`. API-Basis `/admin/api/v1` (überschreibbar per `VITE_API_BASE`), Abbruch/Timeout beim Body-Lesen nicht mehr als `parse`, `router.navigate` trennt Query/Hash und lehnt `//`/Backslash-Ziele ab. Selbst ausgeführt in `pwa/`: lint, svelte-check 0 Fehler, Vitest 11 Tests, Build, Playwright 5 von 5 (inkl. SW-Test: Build-Stamp, kein /admin|/api im Cache, Offline-Shell). Offen: PNG-/maskable-Icons, `/health` unter der Admin-Basis ist weiter Annahme (Vertrag kennt keinen Health-Endpunkt; Backend liefert `/health` im Root), `sw.js` braucht `Cache-Control: no-cache` vom Server, kein Review. Keine laufenden Jobs.

PWA-Icons (30.10.2026): `pwa/public/icon-192.png`, `icon-512.png`, `icon-maskable-512.png` (per Python aus der SVG-Geometrie erzeugt, nicht visuell geprüft) und im Manifest eingetragen; lint/build/Playwright 5/5 grün. F10-PWA damit vollständig. Laufender Job: Claude-reviewer (Ed25519Strict, phpURLPath, Migration, Passkey-Fehlerkategorie) -> docs/paritaet/review-code-korrektur-backend.md; Ergebnis offen.

Review Ed25519Strict/phpURLPath/Migration/Passkey-Kategorie (30.10.2026, Claude reviewer, `docs/paritaet/review-code-korrektur-backend.md`): kein Hoch-Befund im erreichbaren Pfad. Ed25519Strict korrekt (Small-Order-Punkte nachgerechnet); R4 niedrig: weitere Vektoren (R Ordnung 8, Punkt nicht auf Kurve, Torsionsschlüssel), kein CryptoKit-/Linux-Lauf. R1 niedrig: `phpURLPath` weicht in 61 von ~40 000 Zufallsfällen von PHP 8.5.12 ab (heute ohne Außenwirkung; korrigieren oder entfernen). R2 mittel: Passkey-Einheitskategorie nur in poc-passkey, ProblemMiddleware kennt `authentication_failed` nicht → künftiger Login braucht einen Übersetzungspunkt plus HTTP-Test über alle 14 Fälle. R5 Hypothese: Lock-Name serverweit, verschluckter RELEASE_LOCK-Fehler. Behoben vom Koordinator: R3 (`MigrationError.resetHint` nennt kein `DROP DATABASE` mehr, warnt "DEVELOPMENT DATABASES ONLY"; Test angepasst). `sh backend/run-tests.sh` Exit 0; Ergebnis integration-test.sh siehe Lauf unten/FORTSETZUNG. Offen: R1, R2, R4, R5.
Nachtrag: nach R3-Fix lief `P3B_PORT=33417 bash backend/integration-test.sh` mit 31 Tests, 0 Fehler (Koordinator, 30.10.2026); Container entfernt.

Laufender Job (30.10.2026): P5-A Ingest-Kern (Claude implementer, agentId afa7c5ef8e041e6e8, Besitz: backend/Sources/FormIngest, backend/Tests/FormIngestTests, Package.swift, docs/handoffs/P5-A.md). Ergebnis offen, ungeprüft. Bei Abbruch: Diff in backend/ prüfen, Tests neu laufen lassen; keine DB-Tests parallel.

P5-A Ingest-Kern (30.10.2026, Claude implementer, vom Koordinator nachgeprüft): v2-Submit `POST /api/v2/submit/` (+ Alias `/index.php`) in `backend/Sources/FormIngest/` (Signatur ±300 s, Ed25519Strict, Seal nur mit Public Key, Wire-Paket unverändert in stored_objects, Idempotenz mit HMAC-Digest: gleicher Key+Digest → 200 Erst-ID, anderer Digest → 409). Koordinator: `sh backend/run-tests.sh` Exit 0; `P3B_PORT=33417 bash backend/integration-test.sh` 50 Tests, 0 Fehler (13 DB-Ingest-Tests, 8 parallele Requests → 1 Einsendung); `backend/db/check.sh` pass=96 fail=0. Docker-Platte war voll (verwaiste anonyme Volumes durch `docker rm -f` ohne `-v`); beide Testskripte starten MariaDB jetzt mit `--tmpfs /var/lib/mysql`. Die alten Volumes (127 lokal, ca. 13,7 GB rückgewinnbar) habe ich NICHT gelöscht; Aufräumen ist Sache des Nutzers (`docker volume prune`, prüfen ob andere Projekte Volumes brauchen). `IngestSetup.register` ist noch nicht in main.swift verdrahtet (Digest-Secret-Provider D9 fehlt). Nicht umgesetzt: Multipart/Uploads (415), Origin/Bot/CSRF, Technikfelder entfernen, Rate-Limit, Signaturausnahme, Idempotenz-Retention; 413 ungetestet. Offene Vertragsfragen (Details docs/handoffs/P5-A.md): Fehlerhülle (Vertrag `{"error":{code,status}}` vs. ProblemMiddleware `{code,message,requestId}`, 503→500, Retry-After verloren), Klartextformat `{fields,files}` nicht vertraglich definiert, Platzhalter malware_scan_status/environment, 409 bei legacy-missing-Replay, D9. Kein unabhängiges Review.

Laufende Jobs (30.10.2026, Claude, beide nur schreibend in je einer Datei): (1) Review P5-A (reviewer, agentId ac777ddb915c8a51c) -> docs/paritaet/review-p5a-ingest.md; (2) Paketvertrag P5-B (architect, agentId a40adf59fe5b1012a) -> docs/handoffs/P5-B-paket.md. Ergebnisse offen, ungeprüft. Danach: Review-Korrekturen P5-A, P5-B nach Nutzerentscheidungen.

P5-B Paketvertrag liegt vor (30.10.2026, Claude architect, ungeprüft): docs/handoffs/P5-B-paket.md. Empfohlene Aufteilung B1 Auth-Kern (FormAuth: Sitzung/CSRF/Rechte, Passkey-Login mit einem Übersetzungspunkt auf authentication_failed) und B2 Formulare/Release (FormAdmin), Lücken E1–E8 (u. a. keine Draft-Tabelle, Passkey-Code nur in poc-passkey). Wartet auf Nutzerentscheidungen: Schreibrechte Betreuer/Kunde für Entwürfe in P5-B, zweiter Faktor nach Passkey, Schemaänderung für Drafts, B2 parallel mit Stub oder nach B1. Review P5-A läuft noch.

ADR 0007 (Nutzerentscheidungen P5-B: nur Admin schreibt Entwürfe, 2. Faktor Pflicht, Drafts-Schemaänderung erlaubt, B1 vor B2) angelegt. Nächster Schritt: Vertragslücken E1–E8 schließen (architect), dann B1.

Laufender Job: Vertragslücken E1–E8 (architect, agentId a897e39e3dfcd3898; Besitz contracts/auth, contracts/data, backend/db/schema-p3.sql + check.sh, docs/handoffs/P5-B-vertrag-offen.md). Review P5-A (ac777ddb915c8a51c) läuft weiter. Ergebnisse offen.

Review P5-A (30.10.2026, Claude reviewer, `docs/paritaet/review-p5a-ingest.md`, DB-Tests nicht ausgeführt): B1 hoch (Int64-Überlauf im FormEncodedParser trappt den Server vor der Authentifizierung) und B2 mittel (Schlüsselvergleich per Unicode-Äquivalenz statt bytegleich) vom Koordinator BEHOBEN mit je einem Test (`sh backend/run-tests.sh` Exit 0, 52 Tests, 18 DB-Tests ohne DB übersprungen; DB-Lauf nach den Korrekturen nicht wiederholt, da die Änderung nur den Parser betrifft). Offen: B3 mittel (bis 32 MiB vor Auth gepuffert, Parser/Kanonisierung vor Signatur, keine Namenslängen-/Leernamen-Grenzen, kein Rate-Limit), B4 (kein Retry bei Deadlock/Lock-Timeout im Idempotenzrennen → 500), B5–B8 niedrig (Key nicht an Signatur gebunden, 503→500/Fehlerhülle, Formexistenz vor Signatur unterscheidbar, Parserabweichungen zu PHP bei negativem Append-Index/doppeltem f), Testlücken 413, previous-Grenze valid_until=now.

Vertragslücken P5-B (30.10.2026, Claude architect, vom Koordinator nachgeprüft): E1–E8 geschlossen soweit aus ADR 0001–0007 ableitbar (`contracts/auth/p5b-ergaenzung.md`, neue Tabelle `form_drafts`, 69 Tabellen; `contracts/data/schema-entwurf.sql` = `backend/db/schema-p3.sql` per `cmp`). Koordinator: `P3B_PORT=33417 sh backend/db/check.sh` pass=112 fail=0; `bash backend/integration-test.sh` 52 Tests, 0 Fehler (nach Anpassung der hartkodierten Tabellenzahl 68→69 in `SplitterTests.swift`). Offene Fragen F1–F9 mit Empfehlungen: `docs/handoffs/P5-B-vertrag-offen.md` (B1 blockiert durch F4/F5/F9, B2 durch F1–F3, F8). Kein Review der Vertragsergänzung durch Dritte.
ADR 0008 angelegt. B1 (FormAuth) wird gestartet.

NICHT gestartet (30.10.2026, Auto-Mode-Classifier [Data Exfiltration]): P5-B1 Auth-Kern (Claude implementer; Besitz `backend/Sources/FormAuth/`, `backend/Tests/FormAuthTests/`, `backend/Package.swift`, ProblemMiddleware-Mini-Änderung, `docs/handoffs/P5-B1.md`; vermutlich Auslöser: SwiftPM-Download der Argon2id-Abhängigkeit). Nicht umgangen. Wartet auf Nutzerfreigabe. Prompt rekonstruierbar aus ADR 0007/0008, `docs/handoffs/P5-B-paket.md`, `P5-B-vertrag-offen.md`. Entschieden sind F1, F4, F5, F9 (ADR 0008); offen für B2: F2, F3, F8.

P5-B1 nach Session-Neustart erneut abgelehnt (30.10.2026, Auto-Mode-Classifier [Auto-Mode Bypass]); nicht umgangen. Die Regeln in ~/.claude/settings.json (autoMode.allow: SwiftPM/npm-Downloads, Implementer/Architect mit lokalem Docker-MariaDB) sind vorhanden und decken den Auftrag inhaltlich ab; der Classifier wendet sie offenbar nicht an. Wartet auf Nutzerentscheidung (siehe Antwort an den Nutzer).

P5-B1 Slice 1 (30.10.2026, Koordinator direkt, da Agent-Starts abgelehnt und Nutzer "Mach das selber"): Target FormAuth mit Passkey-Kopie, einheitlicher Übersetzungspunkt `authentication_failed` samt HTTP-Test, ProblemMiddleware-Codes nach E4. Fund: RSA-Mindestlänge war mit swift-crypto 3.15.1 für 2047-Bit-Schlüssel wirkungslos (keySizeInBits rundet), jetzt aus DER gemessen (Kopie + PoC). `sh backend/run-tests.sh` Exit 0, poc-passkey 11 Tests 0 Fehler. Details und offene Slices: `docs/handoffs/P5-B1.md`. Kein Review, Argon2id noch nicht aufgenommen.

P5-B1 Slice 2 (30.10.2026, Koordinator direkt): `ServerKeyProvider`/`StaticServerKey` und `SessionService` (DB-Sitzung, Rotation, CSRF) mit 5 DB-Tests; `P3B_PORT=33417 bash backend/integration-test.sh` 73 Tests, 0 Fehler. Offen: Throttles, Rechteprüfung, DB-Repos Challenge/Passkey, Routen/Cookie-Middleware, Passwortprüfer (Argon2id), Review. Details `docs/handoffs/P5-B1.md`.

P5-B1 Slice 3 (30.10.2026, Koordinator direkt): `PermissionService`/`PermissionCatalog` (Live-Rechte, Scope-Schnittmenge, 404/403) und `ThrottleService` (Backoff, Sperre, Budget, HMAC-Subjekte) mit 11 DB-Tests; `integration-test.sh` zweimal 84 Tests, 0 Fehler. Flaky-Test aus P5-A (`wire.contains("Gr")` auf Zufalls-Base64) entfernt. Offen B1: Challenge-/Passkey-Repos, Routen + Cookie/CSRF-Middleware, Passwortprüfer (Argon2id/bcrypt), Review. `docs/handoffs/P5-B1.md`.

P5-B1 Slice 4 (31.10.2026, Koordinator direkt, Nachtarbeit laut Nutzerauftrag "selbstständig"): `LoginService` (Passkey-Schritt mit Challenge-Verbrauch in eigener Transaktion, Dummy-Verifikation, Zählerupdate, Zweitfaktor Passwort mit Sperre) + `PasswordVerifier` (Bcrypt als Zwischenlösung, Argon2id offen) + 9 DB-Tests mit PoC-Vektoren; `integration-test.sh` 93 Tests, 0 Fehler. Nächster Slice: Routen/Cookie/CSRF-Middleware/Client-IP/register, dann Review durch Agent, dann B2 (sobald F2/F3/F8 entschieden). `docs/handoffs/P5-B1.md`.

P5-B1 Slice 5 (31.10.2026, Koordinator direkt): Auth-Routen (`GET session`, `passkey/options`, `passkey/verify`, `second-factor/password`, `logout`) mit Cookie/CSRF/Origin/Budgets (`FormAuth.register`, `AuthGuard.requireAuthenticated` für B2) und 3 HTTP-Tests über die echte DB (Vollablauf, einheitliche 401 für alle Fehlerfälle, Budgets/Validierung); `integration-test.sh` 96 Tests, 0 Fehler. B1 funktional vollständig; offen: Review, main.swift-Verdrahtung (D9), Argon2id (F4). Danach B2.
Hinweis 31.10.2026: Ein Review-Agent für FormAuth (reviewer -> docs/paritaet/review-p5b1-auth.md) wurde vom Auto-Mode-Classifier abgelehnt ([Auto-Mode Bypass]); nicht umgangen. Ersatz: Selbstreview des Koordinators (siehe `docs/handoffs/P5-B1.md`, Abschnitt "Bekannte Lücken"); unabhängiges Review bleibt offen.

P5-B2a (31.10.2026, Koordinator direkt): `FormAdmin` mit `listForms`/`createForm`/`getForm` (Auth + Origin/CSRF + genau eine Rechteprüfung, Scope-Filter in SQL, createForm legt inaktiv an + Audit), `Blob`/`DB` nach FormPersistence zusammengeführt; `integration-test.sh` 100 Tests, 0 Fehler, `run-tests.sh` Exit 0. Offene Annahme G1 (`getForm`-Projektion). Nicht verdrahtet in `main.swift`. Offen: Entwürfe/Release (F2/F3/F8, RFC 8785), Review FormAuth/FormAdmin (Agent abgelehnt), Argon2id (F4), P5-A B3–B8. Details `docs/handoffs/P5-B2.md`, `docs/handoffs/P5-B1.md`.

P5-A Nachtrag (31.10.2026, Koordinator): Review-Befunde B3 (teilweise: Segment-/Namensgrenzen im Parser) und B4 (ein Retry bei 1213/1205/Duplikat ohne Gewinnerzeile) umgesetzt, Tests ergänzt; `integration-test.sh` 101 Tests, 0 Fehler. Neu: `FormCore/JCS.swift` (RFC 8785 + strenger Parser: nur ganze Zahlen ±(2^53-1), keine Duplikate, UTF-16-Schlüsselsortierung) mit `JCSTests` (Gegenprobe gegen Python `json.dumps(sort_keys)` für die Teilmenge; RFC-Sortierbeispiel); `run-tests.sh` Exit 0, 106 Tests. ADR 0008 F1 damit umgesetzt (Hash = SHA-256 darüber, noch nicht in Draft-Operationen verwendet).

Verdrahtung (31.10.2026, Koordinator): `AppConfig.admin` + `FileServerKey` + `main.swift` (Admin-API nur mit vollständiger Konfiguration, fail closed Exit 78, nicht bei `migrate`); neues `backend/smoke-admin.sh` (echte Binary + Docker-MariaDB: migrate/health/session/Cookie/401/Schlüssel nicht im Log/lockerer Schlüssel → 78) alle ok; `run-tests.sh` Exit 0 (110 Tests), `integration-test.sh` siehe Lauf. Ingest bleibt unverdrahtet (Digest-Secret-Provider offen).

Prüfstand 31.10.2026 (Koordinator, nach sauberer Neuübersetzung `rm -rf backend/.build/arm64-apple-macosx`): `P3B_PORT=33417 bash backend/integration-test.sh` 110 Tests, 0 Fehler; `bash backend/smoke-admin.sh` 8/8 ok; `sh backend/run-tests.sh` Exit 0. **Hinweis zur Umgebung:** Nach Layoutänderungen an Strukturen (z. B. `AppConfig`) lieferte der native Inkrementalbuild veraltete Abhängige (xctest SIGSEGV beim ersten `IngestDBTests`-Test, pc=0). Abhilfe: `rm -rf backend/.build/arm64-apple-macosx/debug/<Target>.build` bzw. das ganze Verzeichnis `backend/.build/arm64-apple-macosx`. Bei unerklärlichen Abstürzen zuerst so neu bauen.

PWA-Anmeldung (31.10.2026, Koordinator direkt): `createAuthApi`, `webauthn.ts`, zustandsbasierte `Login.svelte` gegen die Auth-Routen; `npm run lint/check/test` (19 Tests), Build, Playwright 6/6 (Ablauf mit gemockter API und gestubbtem Authenticator) grün. Nicht geprüft: echter Authenticator gegen echtes Backend, axe. Details `docs/handoffs/P4-B.md`.

E2E-Login (31.10.2026, Koordinator): `backend/e2e-login.sh` (Chromium-virtueller-Authenticator → Proxy → App-Binary → MariaDB) 1/1 bestanden, sign_count=2, Secrets nicht im Log; belegt echte Browser-WebAuthn-Antworten und `$2y$`-Bcrypt gegen das Backend. `pwa/e2e-real/` ist Testhilfe, nicht Teil der normalen `playwright test`-Läufe. Details `docs/handoffs/P5-B1.md`.

PWA axe (31.10.2026, Koordinator): `@axe-core/playwright` 4.14.0 (MPL-2.0, dev-only) aufgenommen; Playwright 9/9 inkl. 3 axe-Tests (WCAG 2.x A/AA, hell/dunkel, Passwortschritt/Fehler) ohne Verstöße. Manuelle Screenreader-/Tastaturprüfung offen.
npm audit (pwa, 31.10.2026): `--omit=dev` 0 Schwachstellen; gesamt 15 (2 low, 13 moderate), alle in Build-/Lint-Werkzeugen (u. a. `deepmerge` via vite-plugin-svelte ohne Fix, `minimatch` via eslint, Fix nur per breaking `eslint@4`); werden nicht ausgeliefert. Bewertung offen, kein `audit fix --force`.

Aufräumdienst (31.10.2026, Koordinator): `AuthMaintenance`/`AuthMaintenanceScheduler` (Sitzungen/Challenges/Throttles, 7 Tage Aufbewahrung als Vorschlag, Referenzschutz) in `main.swift` verdrahtet; `integration-test.sh` 112 Tests, 0 Fehler; `smoke-admin.sh` siehe Lauf.

Remote/CI/Linux (31.10.2026, Koordinator): Privates GitHub-Repo `MagicalWig34653/form-backend` angelegt, `main` gepusht (Nutzerauftrag). `FormCrypto` von CryptoKit auf swift-crypto (`import Crypto`) umgestellt (Voraussetzung für Linux; macOS-Tests weiter grün, `rm -rf backend/.build/arm64-apple-macosx` davor). **Linux-Nachweis:** `swift build --product App` und `swift test` in `swift:6.3-noble` (linux/arm64, Docker Desktop) bestanden; `bash backend/ci-linux.sh` (MariaDB + Swift auf privatem Docker-Netz, alle DB-Tests): 112 Tests, 0 Fehler. Tests portabel gemacht (Glibc-Sockets), Fixtures kennen `P4A_DB_HOST`. Neu: `backend/Dockerfile` (Multi-Arch, Runtime `swift:6.3-noble-slim`, nicht root), `.dockerignore`, `.github/workflows/ci.yml` (Linux-Tests amd64 + arm64 nativ, PWA lint/check/test/build/Playwright/audit, Docker-Image amd64+arm64 mit Push nach GHCR nur auf main). **Nicht lokal geprüft:** Image-Build bis zum Ende (Docker-VM-Platte voll, 132 alte Volumes/20 GB rückgewinnbar; ich habe keine fremden Daten gelöscht) und amd64 (nur arm64 nativ); Ergebnis der GitHub-Läufe siehe unten.

Argon2id (31.10.2026, Koordinator, Nutzerentscheidung F4 "Argon2id jetzt"): `phc-winner-argon2` (CC0-1.0 OR Apache-2.0) per Commit gepinnt, `Argon2id` + `DefaultPasswordVerifier` (Legacy-Bcrypt bleibt prüfbar) + 6 Tests (PHP-Interop in beide Richtungen); `integration-test.sh` 118 Tests, 0 Fehler; `e2e-login.sh` mit Argon2id und Bcrypt je 1/1; Linux arm64 bestanden. Parameter nicht gemessen. GitHub CI Lauf 41172889889: Linux amd64 + arm64 und PWA erfolgreich, Image-Job siehe unten.

GitHub CI (31.10.2026, Lauf 41189627285 auf main): alle Jobs erfolgreich: Backend-Tests Linux amd64 und arm64 (nativ, mit MariaDB, 118 Tests), PWA (lint/check/Vitest/build/Playwright inkl. axe/audit), Docker-Image je Architektur nativ gebaut, Multi-Arch-Manifest `ghcr.io/magicalwig34653/form-backend:latest` (+ Commit-SHA) für linux/amd64 und linux/arm64 veröffentlicht (privates Paket im GHCR des Nutzerkontos). Ein früherer Lauf scheiterte am vollen Runner-Datenträger (QEMU-Build): behoben durch native Builds, Platzfreigabe, `-gnone`+strip. Das Image wurde noch NICHT gestartet/getestet (nur gebaut). ADR 0009 hält die Entscheidungen F2/F3/F8/G1/F4 fest. Nächster Schritt: Entwürfe/Release (F2: Standard-Entwurf beim Anlegen), Flow-Vertrag `security.specialCategories`, `getForm`-Projektion.

P5-B2b (31.10.2026, Koordinator direkt): Entwürfe + Veröffentlichung (createDraft/getDraft/updateDraft, confirmPublication, publishRelease, Standard-Entwurf beim Anlegen, getForm-Projektion, DocumentValidator-Teilmenge); `integration-test.sh` 123 Tests, 0 Fehler. Befund MariaDB-Snapshot-Isolation (Fehler 1020) und Sperrreihenfolge dokumentiert. Details `docs/handoffs/P5-B2.md`. Offen: Flow-Vertrag `specialCategories`, Reauthenticate, Ingest-Ende-zu-Ende, Review.

Doku-Seite, README, Auslieferung der PWA (31.10.2026, Koordinator direkt, Nutzerauftrag): `site/` (abhängigkeitsfreier Generator `build.mjs`, Prüfung `check.mjs`: Links/Anker/Struktur; 8 Seiten: Start, Einrichtung, Benutzung, Admin-API, Sicherheit, Architektur, Stand & Roadmap, Entwicklung; hell/dunkel, mobil, Inhaltsverzeichnis, Kopieren-Knöpfe). Geprüft: Linkcheck ok; axe (WCAG 2.x A/AA) auf allen 8 Seiten in hell und dunkel ohne Verstöße (nach Korrektur fokussierbarer Tabellenbereiche); Mobilansicht 390 px ohne Überlauf. Workflow `.github/workflows/ci.yml` baut die Seite (`--base /form-backend/`) und deployt auf GitHub Pages (nur main; Pages per API mit `build_type=workflow` aktiviert: `https://magicalwig34653.github.io/form-backend/`). **Hinweis:** Pages ist öffentlich, auch wenn das Repository privat ist; die Seiten nennen ehrlich auch Sicherheitsgrenzen. PWA: Link "Dokumentation" (neuer Tab, `noopener noreferrer`, `VITE_DOCS_URL` überschreibbar) + Test; Playwright 10/10, Vitest 19. Backend liefert die PWA aus (`StaticSiteMiddleware`, `FORM_PUBLIC_DIR`): Pfadsicherheit (Traversal/Dotfiles/NUL), SPA-Fallback nur für Pfade ohne Endung und nie für API-Präfixe, Cache-Regeln (hashed `/assets` immutable, sonst `no-cache`), CSP (nur eigene Herkunft, keine Inline-Skripte, `frame-ancestors 'none'`); Tests `StaticSiteTests`; `e2e-login.sh` läuft jetzt gegen den echten Server mit ausgelieferter PWA (bestanden). `deploy/docker-compose.yml` (config validiert) + `Caddyfile.example`. Dockerfile setzt `FORM_PUBLIC_DIR=/app/public`. Neu verfasste README. Entwurfs-Körper bis 1 MiB (Vapor-Standard waren 16 KiB) mit Test. `integration-test.sh` 128 Tests, 0 Fehler. Nicht geprüft: der Compose-Beispielbetrieb als Ganzes (Image-Start mit PWA, Caddy, echte Domain), GHCR-Pull aus fremder Umgebung.

Swarm/Replicas (31.10.2026, Nutzervorgabe: primär Docker Swarm, Container zustandslos, MariaDB hält alle Daten): Audit ergab keinen Prozesszustand außer dem Bereitschafts-Gate je Instanz. Neu: `FORM_DB_PASSWORD_FILE` (Docker-Secret), `/ready` = 503 bis das Schema angewendet ist (nur im echten Server, `requireSchema`), Aufräumdienst nur auf einer Replica gleichzeitig (`GET_LOCK`, getestet), `deploy/swarm-stack.yml` (3 Replicas, rollendes Update start-first mit Rollback, `migrate`-Einmaldienst, Secrets uid 10001/0400, overlay intern) + `Caddyfile.swarm` (dynamische Upstreams `tasks.app`, Health `/ready`). `backend/smoke-replicas.sh` (zwei echte Instanzen, eine DB): 9/9 ok (Sitzung A→B, CSRF, Logout B wirkt auf A, Budget gemeinsam, 503 vor Migration, Passwort aus Datei). `integration-test.sh` 130 Tests, 0 Fehler. Nicht getestet: echter `docker stack deploy` (würde Swarm-Modus auf dieser Maschine aktivieren), Caddy-dynamic-upstreams, Rolling-Update. Grenzen: Client-IP hinter dem Load-Balancer (alle Nutzer teilen das Budget), DB als Einzelpunkt (Replikation/Galera nicht enthalten), Ingest noch nicht verdrahtet (er wäre ebenfalls zustandslos).

Erstkonto + Passkey-Registrierung + vertrauenswürdige Proxys (31.10.2026, Koordinator direkt): `bootstrap-admin`/`enroll-passkey`, Einmal-Link `/setup#token`, Registrierung ES256/EdDSA/RS256 (strenger CBOR-Leser, Attestation none), zweite Tür für angemeldete Sitzungen (frische Anmeldung), `FORM_TRUSTED_PROXIES` (X-Forwarded-For von rechts), Schema `account_enrollments` (70 Tabellen), PWA `/setup`. `integration-test.sh` 147 Tests, 0 Fehler; `check.sh` 117/117; neue `backend/e2e-setup.sh` (leere DB → Link → echter Browser-Authenticator → Login) bestanden; Vitest 24, Playwright 10. Doku-Seite aktualisiert. Details `docs/handoffs/P5-B1.md`. Offen: Passkey-Verwaltung/Entfernen, Konten-/Rechteverwaltung, Ingest-Verdrahtung, PHP-SDK, Mail, Review.

Eingang aktiviert (31.10.2026, Koordinator direkt, Nutzer "ja weiter"): `managed_secrets` + `SecretStore` (D9), `IngestSetup` in `main.swift`, Admin-Operationen `customer-key` und `sdk-credentials` (Einmal-Ausgabe des Signaturschlüssels, Rotation mit 1 h Frist), Ende-zu-Ende-Test bis zur Entschlüsselung durch den Kunden. `integration-test.sh` 151 Tests, 0 Fehler; `check.sh` 120/120; `smoke-admin.sh` inkl. Ingest-Route; Doku-Seite aktualisiert. Details `docs/handoffs/P5-A.md` (Nachtrag). Offen: PHP-SDK, Browser-Schlüsselverwaltung, Multipart, Mail, Review, Vertrag (OpenAPI) für die neuen Operationen.

PHP-SDK (31.10.2026, Koordinator direkt, Nutzer "weiter"): `sdk/php/` (Client, Credentials, Canonical, CurlTransport, Exceptions, `bin/submit.php`, `composer.json`, README). Signiert und sendet; das SERVER versiegelt beim Eingang (Korrektur: README/Doku sagten fälschlich, das SDK versiegele; jetzt ehrlich: kein Browser-Ende-zu-Ende, Klartext nur im Speicher während der Anfrage, gespeichert wird Chiffrat). Eigenschaften: HTTPS-Pflicht (http nur localhost), Zugangsdatei muss 0600 sein, Seed/Public-Key-Paar geprüft, Seed nie in Ausgaben, Wiederholung 3× mit gleichem Idempotency-Key und frischer Signatur, strenge Eingabeprüfung (kein stilles Umbenennen/Konvertieren), Fehlermeldungen ohne Serverfreitext/Werte, Antworten ≤ 64 KiB, keine Redirects. Nachweise: `php sdk/php/tests/sdk_test.php` 87 Prüfungen (PHP 8.5); **echter Test** `IngestEndToEndTests.testPHPSDK…`: PHP-SDK-Prozess gegen echten Swift-Server (loopback) → 200, Retry gleiche ID, 409, 403, 404, Transportfehler (Exit 2), Usage (64), Kunde entschlüsselt exakt die gesendeten Felder; läuft auch unter Linux arm64 im Container (PHP dort per apt). `integration-test.sh` 152 Tests, 0 Fehler. Fund: PHP 8.5 meldet `curl_close()` als veraltet (Ausgabe auf stdout) → entfernt, CLI schreibt Diagnosen nach stderr. CI: neuer Job `php-sdk` (PHP 8.2/8.3/8.4), `ci-linux.sh` installiert PHP im Container. Doku-Seite um "PHP-SDK" erweitert (9 Seiten, Linkcheck ok). Nicht geprüft: PHP 8.2–8.4 lokal (nur in CI), Hosting mit eingeschränktem cURL, Multipart-Uploads (fehlen), unabhängiges Review. Offen: Docker-Kundenagent, Pairing, Domain-/Webserver-Zuordnung, Mail.

Mailversand mit Inhalt (31.10.2026, Koordinator direkt, Nutzerentscheidung "wie im alten Backend", ADR 0010): Target `FormMail` (Nachricht/Vorlagen/SMTP-NIO/Mail-Proxy/Zielschutz/`MailDispatcher`), `form.mail` im Formular (Vertrag + Validator + Beispiele), Zustellzeilen in der Einsendungs-Transaktion, Versand nach dem Commit, kein Auto-Retry, `uncertain` nach Lease-Ablauf, Admin-API für Verbindungen/Zuordnung/Zustellstatus, `FORM_MAIL_ALLOWED_NETS`. Nachweise: Unit-Tests gegen scriptbaren SMTP-Server und Fake-Proxy, 6 DB-Ende-zu-Ende-Tests (u. a. Inhalt in keiner DB-Spalte), echter Mailserver Mailpit (`backend/mail-interop.sh`, auch in `ci-linux.sh`, Linux arm64 bestanden); `integration-test.sh` 186 Tests, 0 Fehler; Flow-Validator 12/21/53. Offen: manueller Wiederversand (Browser-Entschlüsselung), Anhänge, Test-/Produktivempfänger, OpenAPI-Eintrag, Review. Details `docs/handoffs/P5-C.md`.

PWA-Verwaltungsoberfläche P5-E (31.10.2026, Koordinator direkt): Kunden, Formulare, Felder, Mail-Versand, Veröffentlichen (mit frischer Anmeldung und Versionserhöhung), Kundenschlüssel, SDK-Zugangsdaten, Verbindungen. Backend-Verzeichnisendpunkte (`/me`, `/tenants`, `/tenants/{t}/connections`) mit Tests. Vitest 42, Playwright 28 (inkl. axe auf 8 Admin-Seiten), echter E2E `backend/e2e-admin.sh` bestanden (belegt: im Browser berechneter JCS-Hash = Serverhash). Details `docs/handoffs/P5-E.md`. Offen: Konten-/Rechte-/Passkey-Verwaltung, Browser-Entschlüsselung, Statistik, Resend, Schlüsselrotation, unabhängiges Review.

Einsendungen lesen (31.10.2026, Koordinator direkt): Admin-Operationen `entries`/`ciphertext` (Metadaten bzw. versiegeltes Paket, Rechte `content.read`+`content.decrypt`, frische Anmeldung, Audit), PWA-Tab „Einsendungen“ mit Entschlüsselung im Browser (WebCrypto, HPKE von Hand; privater Schlüssel nur im Arbeitsspeicher). Nachweise: `integration-test.sh` 192 Tests, 0 Fehler; PWA lint/check, Vitest 47, Build, Playwright 31/31 (axe, echte Entschlüsselung eines PHP-versiegelten Pakets in Chromium). Grenzen: keine PRF-/Recovery-/Datenzugangsverwaltung, keine Anhänge, kein Review, Firefox/Safari ungeprüft. Details `docs/handoffs/P5-F.md`.
Review P5 Auth/Einsendungen (01.11.2026, Claude reviewer, statisch; `docs/paritaet/review-p5-auth-entries.md`): keine hohen Befunde; M1–M3 und mehrere niedrige Befunde vom Koordinator behoben (Low-Order-Schlüssel, NULL-`received_at` im Cursor, deaktivierter Kunde, Browser-Rennen), `integration-test.sh` 192/0 Fehler, PWA 47 + Playwright 31. Offen: Review von Passkey/CBOR, Registrierung, Bootstrap, PasswordVerifier, Drafts, MailRoutes, ClientIP, Service Worker (Codex ab 04.11.); niedrige Befunde siehe `docs/handoffs/P5-F.md`. Außerdem `contracts/auth/p5-implementiert.openapi.yaml` (Abbild der umgesetzten Operationen).
Statistik Teilumfang P5-D (01.11.2026, Koordinator): tägliche Zählung angenommener Einsendungen (`/statistics`, Recht `statistics.read`) + Balkenanzeige im Überblick; `integration-test.sh` 193/0 Fehler, PWA Playwright 32/32. Ereignisstatistik (Besuch/Abbruch) wartet auf Ansichten/Domains (P7). Details `docs/handoffs/P5-D.md`. Laufender Job: Review `docs/paritaet/review-p5-rest.md` (Claude reviewer, Passkey/Registrierung/Mail/Drafts/Static/SW), Ergebnis offen.
Review P5 Rest (01.11.2026, Claude reviewer, statisch + run-tests/npm test; `docs/paritaet/review-p5-rest.md`): keine hohen Befunde (Passkey/CBOR/DER, Einmal-Token, Bootstrap, SSRF-HostGuard, Header-Injection, Entwurfs-If-Match, Static-Site/CSP, SW-Allowlist ohne Befund). Behoben vom Koordinator mit Tests: M1 (alle X-Forwarded-For-Zeilen zusammenführen, `ForwardedForTests`), M2 (STARTTLS-Barriere gegen eingeschleusten Klartext; Test belegt: ohne Barriere lief die Sitzung mit gefälschtem „250“ weiter, mit Barriere bricht sie ab), M3 (Mail-Lease wird beim Sendestart erneuert; Zeile nicht mehr `leased` → nicht senden), `encodeURIComponent` im Chiffrat-Pfad. `integration-test.sh` 195 Tests: 4 Läufe 0 Fehler, 1 früherer Lauf mit 1 nicht identifiziertem Fehler (nicht reproduzierbar; SMTP-Suite 8× stabil). Offen (niedrig): IP-Literal als SMTP-Host (NIOSSL-Verhalten ungeprüft), `$` in Regexen lässt `\n` zu, freie Absenderadresse, Bestätigungsmail-Relay, Argon2/bcrypt blockieren Pool-Thread, Passkey-Limit nur in `begin`, Entwurfs-Obergrenze, Steuerzeichen im ACODE, Content-Type sw.js/manifest ungeprüft, 6to4/Teredo im HostGuard.
Manueller Mail-Resend P5-G (01.11.2026, Koordinator): `POST …/entries/{e}/resends` mit Inhaltsschlüssel aus dem Browser (originalProof), Server öffnet sein gespeichertes Paket, rendert neu, übernimmt dieselbe Zustellzeile; PWA-Knopf. `integration-test.sh` 196/0 Fehler, PWA Vitest 48, Playwright 32/32. Details `docs/handoffs/P5-G.md`. Review des Resend läuft (Claude reviewer → `docs/paritaet/review-p5g-resend.md`).
Browser-Schlüsselverwaltung P5-H (01.11.2026, Koordinator): Datenschlüssel im Browser, Kontoschlüssel per Passkey-PRF, Datenzugang (HPKE), Recovery-Code, Server nur Blobs; Registrierung fordert `prf` an. `integration-test.sh` 197/0 Fehler, Vitest 53, Playwright 32/32, echter Browserlauf `e2e-setup.sh` (PRF-Entsperren + Recovery) bestanden. Details `docs/handoffs/P5-H.md`; Review läuft → `docs/paritaet/review-p5h-keys.md`.
Review-Korrekturen P5-H und Gesamtkette (02.11.2026): Fingerabdruck-Vergleich beim Erteilen, Lock bei Logout, Recovery-Code-Kontrolle, Selbstreparatur; `e2e-setup.sh` deckt Registrierung → Browser-Schlüssel → PHP-SDK-Einsendung → Entschlüsselung im Browser ab (bestanden). `integration-test.sh` 197/0 Fehler, Playwright 32/32. Offen: Konten-/Rechte-/Passkey-Verwaltung in der UI, Entzug/Rotation, Multipart, P6, P9, Zweitreview (Codex ab 04.11.).
Konten/Rechte/Passkeys P5-I (02.11.2026, Koordinator): Konto anlegen (Einmal-Link), Mitgliederrechte je Kunde mit Eskalationsschutz, eigene Passkeys auflisten/entfernen; PWA-Seiten. `integration-test.sh` 198/0 Fehler, Playwright 37/37 (axe), `e2e-setup.sh` bestanden. Details `docs/handoffs/P5-I.md`; Review läuft → `docs/paritaet/review-p5i-accounts.md`.
Datei-Uploads P5-J (02.11.2026, Koordinator): Multipart am Eingang (Typ-/Größenprüfung, je Anhang versiegelt), SDK `--file`, Anhang-Download im Browser mit Hashprüfung. `integration-test.sh` 199/0 Fehler, Playwright 37/37, `e2e-setup.sh` (SDK-PDF → Browser-Download) bestanden. Details `docs/handoffs/P5-J.md`. Nutzerwunsch SDK-Selbstupdate (optional, FTP/SFTP, Rollback) im ARBEITSPLAN als P7-U. Codex-Astra-Security-Review läuft (`docs/paritaet/review-codex-astra-1.md`, Task task-mvz4wy07-1i3ps4).
SDK-Selbstupdate P7-U (02.11.2026, Koordinator): FTP/FTPS-Installer mit Staging, Hash-Verifikation, Rollback, optionaler Automatik; Admin-API; ADR 0011. `integration-test.sh` 209/0 Fehler. Details `docs/handoffs/P7-U.md`. Ablösung des Altbackends: noch nicht bereit (Migration P9, Parität P8/P7, Engine P6, Betrieb P10, Rotation, externes Audit offen).
SFTP für das SDK-Selbstupdate (02.11.2026, Koordinator): SFTP v3 über swift-nio-ssh, Host-Key-Pinning (Pflicht, `probe-sftp`), gemeinsame Installer-Logik für FTP/FTPS/SFTP. Gegen echten OpenSSH-Server getestet (`backend/sftp-test.sh`, 2 Tests); `integration-test.sh` 211 Tests, 0 Fehler (5 übersprungen: Mailpit, SFTP-Server). Details `docs/handoffs/P7-U.md`, ADR 0011 Nr. 8.
Codex-Astra-Review 2 (Uploads + SDK-Selbstupdate, 02.11.2026, `docs/paritaet/review-codex-astra-2.md`): 14 Befunde (4 hoch). Behoben mit Tests: H1 (Zertifikatsprüfung nur mit Entwicklungsfreigabe abschaltbar), H2 (Ziel/Installation brauchen `key.manage` am Kunden), H3 (Löschen folgt keinen Links, LSTAT, sichere Namen), H4 (passive FTP-Antwort kann nicht mehr abstürzen, Promise-Leck beseitigt), M3, M4, M7, M8, L2. Offen: M1 (gemeinsames physisches Ziel/Zielrevision), M2 (Lauf-/Phasenpersistenz, Reparaturzustand), M5 (Ingest-Budget, P10), M6 (Deadlines/Puffer), L1 (Parser-Differentialtests). **Automatische SDK-Updates bleiben bis M1/M2/M6 behoben sind als „nicht freigegeben“ zu betrachten** (Standard ist ohnehin aus).
Löschung/Hold/Aufbewahrung/Export P8-A (02.11.2026, Koordinator): Einzel-/Stapellöschung (`content.delete`), Hold (`content.hold`), Aufbewahrungsfrist je Formular (`privacy.manage` am Kunden) mit stündlichem Job (`RetentionScheduler`, Cluster-Lock) und Chiffrat-Export seitenweise (`content.export`+`content.read`); alles mit frischer Anmeldung und Audit; Löschnachweis in `deletion_records`. Der Eingang setzt neue Einsendungen auf löschbar (`removable=1`) und berechnet `retention_due_at`. ADR 0012; Tests `PrivacyTests` (3, bestanden). Offen: PWA-Oberfläche (Löschen/Hold/Frist/Export-Download), Hold-Rewrap bei Rotation, externe Speicher, Review Codex-Astra 3 (5 Befunde, alle behoben, `docs/paritaet/review-codex-astra-3.md`). Gesamtlauf `integration-test.sh` 221 Tests, 0 Fehler, 5 übersprungen (ein früherer Lauf blieb einmal in `SDKDeployTests` hängen, nicht reproduzierbar).
PWA zu P8-A (03.11.2026): Einsendungs-Tab mit Löschen, Löschschutz, Aufbewahrungsfrist und Export (verschlüsselt, oder lokal entschlüsselt); Liste liefert `held`. Vitest 59, svelte-check 0, Playwright 38/38, Backend-Tests grün.
Laufende Jobs (03.11.2026): Codex-Task `task-mw0bgx3a-1i0vnn` baut den Branch `deploy` (Worktree `../form-backend-deploy`, Swarm + Compose, Setup-/Update-Skripte, Backup/Restore, Workflow zur automatischen Erzeugung; Vorbild `../todo`). Codex-Task `task-mw0bhv8n-26cgeh` implementiert Webhooks (Worktree `../form-backend-webhooks`, Branch `feature-webhooks`, ADR 0013). Beide arbeiten ungecommittet; nach Abschluss: Ergebnis prüfen, Review, in den jeweiligen Branch committen, Webhooks nach `main` mergen. Nutzervorgabe 03.11.: mindestens 50 % der delegierbaren Arbeit an Codex.

## P9 Datenmigration (03.11.2026, Implementierung mit offener Abnahme)

Worktree `form-backend-migration`, Branch `feature-migration`, ungecommittet, kein Push. Neues `FormMigration` und CLI `App migrate-legacy`: expliziter Plan, read-only-Quellsnapshot, Zielsperre, objektweise Transaktionen/Ledger, HMAC-Paritätsbericht, Batches/Wiederaufnahme und vollständiger Rollback beim Prüflauf. Kunden, öffentliche Altschlüsselgenerationen, inaktive Formulare/Felder/Mailkonfiguration, SecretStore-Verbindungen/Webhooks, Einsendungen/v2-Pakete, Alt-Idempotenz und verschlüsselte `legacy_statistics`; unsupported Inhalte als Review. Keine Aktivierung/Worker/Entschlüsselung. ADR 0014 und vollständige Grenzen/Dateiliste unter `docs/handoffs/P9.md`.

Prüfungen: vorgegebener Aufruf `P3B_PORT=33419 P3B_NAME=migration-mariadb ./backend/integration-test.sh --filter Migration` scheitert vor Tests mit Exit 2 (Docker-Socket gesperrt). SwiftPM-Build scheitert an fehlendem Argon2-Dependency-Cache im Worktree. Alternative Swift-Typprüfung gegen ausschließlich gelesene Dependency-Module des Hauptworktrees für Importer/Command und Tests erfolgreich; Syntax/Diff geprüft. **Kein erfolgreicher Build, kein ausgeführter Integrationstest, keine Produktionsreife behauptet.** Fixture nur Migrations-Tabellenausschnitt, kein vollständiger Alt-Migrationslauf. Vollständige Konto-/Schlüsselzugangs-/Historienmigration, aktuelles Veröffentlichungsformat, finaler Delta-/Löschabgleich und unabhängiges Review offen. Keine laufenden Jobs, alleiniger Dateibesitz dieses Pakets; Todolino-Werkzeuge nicht verfügbar. Nächster Schritt: Build/Integration mit zugänglicher Laufzeit, Befunde korrigieren, Review und Mappingrest vor Cutover.

### P9 Fehlerkorrektur: numerische HEX-Projektion (03.11.2026)

Nutzerprüfung gegen Docker/MariaDB: beide ursprünglichen Migrationstests scheiterten mit `ImportFailure.invalidSource`. Ursache im Importer, nicht in der Fixture: `HEX(INT)` konvertiert den Zahlenwert zur Basis 16 (`ID=1` → `1`), der Reader erwartet hingegen hexkodierte Textbytes (`31`). `projection` verwendet jetzt `HEX(CAST(spalte AS BINARY))`; native UUID-Spalten werden anhand `information_schema` erkannt und ausdrücklich vor HEX zu CHAR/utf8mb4 konvertiert. BINARY/VARBINARY/BLOB bleiben bytegenau, NULL bleibt NULL. Gilt für Hauptimport, eingebettete Formularfelder, Ziel-Snapshots und Test-Fingerprints. Fixture mit Alt-DDL abgeglichen, unverändert.

Diagnostik: kontrollierter Fehler `invalidSourceAt` mit Tabelle/Spalte und festem Grundcode für Dekodierung/UUIDs/Schema/Cursor/Zahlen/Zeit/Bool; weder Werte noch SQL noch Decoderfreitext. Fehler werden nach Objektrollback weitergegeben und vom CLI sicher angezeigt, nicht mehr pauschal als Datenbankfehler verdeckt. Schema-/Dekodierungsfehler erzeugen keinen stillen Review-Erfolg.

Geändert: drei Swift-Dateien unter `backend/Sources/FormMigration/`, bestehende `MigrationTests.swift`, neue `MigrationDecodingTests.swift`, STATUS/ARBEITSPLAN/Handoff/ADR 0014. Vollständiger SwiftPM-Build inklusive App-Link und Kompilierung aller Tests jetzt erfolgreich (`swift test … --filter MigrationDecodingTests`, nativer Builder mit Caches im Repo). **3 lokale Regressionstests, 0 Fehler**; `git diff --check` erfolgreich. Zusätzlicher DB-Projektionstest für INT/DECIMAL/BOOLEAN/native UUID/CHAR(36)/BINARY(16)/Blob/Unicode/NULL kompiliert, nicht ausgeführt. Erneute MariaDB-Prüfung erfolgt durch den Nutzer mit unverändertem Port 33419/Namen migration-mariadb. Vorherige DB-Fehler noch nicht als bestanden bestätigt. Branch `feature-migration`, ungecommittet, keine laufenden Jobs. Nächster Schritt: Nutzer führt `P3B_PORT=33419 P3B_NAME=migration-mariadb ./backend/integration-test.sh --filter Migration` aus.

### P9 Reviewkorrekturen (03.11.2026)

Drei beauftragte Befunde in `LegacyImporter.swift`/`Transform.swift` behoben: unbeschränkte erste Cursor-Seite einschließlich negativer IDs und Inventar-/Scan-Abgleich (`countMismatch` verhindert Verification), belegte unbekannte Formularspalten als `unmapped-column` auch bei Ledger-Wiederholung, Status/Abschlusszeit unabhängig von Berichtsänderung. Vier DB-Regressionsfälle ergänzt und kompiliert; wegen nicht verfügbarem Docker ausdrücklich nicht ausgeführt. SwiftPM-Build/Link mit lokalem Filter `MigrationDecodingTests` erfolgreich, 4 lokale Tests/0 Fehler, Diffprüfung erfolgreich. ADR 0014 und Handoff P9 aktualisiert. Dateibesitz: FormMigration-Importer/Transform, die zwei Migration-Testdateien und diese Dokumentation, keine parallelen Schreiber. Worktree `form-backend-migration`, Branch `feature-migration`, alles ungecommittet, kein Push, keine laufenden Jobs. Nächster Schritt: DB-Abnahme durch Nutzer mit `P3B_PORT=33419 P3B_NAME=migration-mariadb ./backend/integration-test.sh --filter Migration` (7 DB-/4 lokale Tests); Details/Grenzen in `docs/handoffs/P9.md`.
Weitere Codex-Jobs (03.11.2026): `task-mw0bvuir-si6yv7` P9-Importer (Worktree `../form-backend-migration`, Branch `feature-migration`, synthetische Alt-DB, ADR 0014), `task-mw0bvv4i-v4m587` Domainzuordnung + Ereignisstatistik (Worktree `../form-backend-domains`, Branch `feature-domains`, ADR 0015). Nutzervorgaben für den Deploy-Branch: kein Caddy im Stack, TLS durch externen Reverse Proxy, Datenbank extern, möglichst alles per ENV (Vorbild `../timetrack-backend/deploy`); wird als Nachbesserung an den Deploy-Job gegeben, sobald dieser fertig ist. Nutzerziel: Ablösung des Altbackends möglichst heute Abend; ehrlicher Rest siehe `docs/ABLOESUNG.md` (echte Datenmigration braucht Altdaten-Kopie, Rotation, P6, externes Audit).

## P-Rotation (03.11.2026, Branch feature-rotation, ungecommittet)

Datenschlüsselrotation mit Beginn, vollständigem seitenweisem Objektinventar, Browser-CEK-Rewrap, Revision-/Digest-CAS und Abschluss ausschließlich bei null Altreferenzen implementiert. Zugänge/Recovery/Generation werden erst danach atomar entfernt; Audit mit Quell-/Ziel-kid. Eingang prüft unter gemeinsamer Kundensperre die aktive Generation erneut. Zugangsentzug betrifft alle Generationen, letzte handlungsfähige Identität muss alle aktiven/auslaufenden Generationen abdecken; Kontoschlüsselersatz und Rechteentzug entsprechend geschützt. Hold jetzt mit vollständiger Objektliste und atomarem HPKE→sym-Nachschutz inklusive rekursiver Metadaten statt Flag-only. Schlüssel-Tab mit Fortschritt; feste Browser→Swift-Interop-Vektoren.

Prüfungen: PWA 67 Vitest erfolgreich, check/lint/build erfolgreich. Swift-Build und gezielte Rotation/Privacy-Prüfungen erfolgreich (18 Tests, davon 15 ohne DB übersprungen; drei ausgeführte Prüfungen inkl. Interop und Server-Invarianten). Vorgeschriebener DB-Aufruf mit **P3B_PORT=33421 P3B_NAME=rotation-mariadb** endet Exit 2: Docker-Daemon nicht erreichbar. Zusätzlicher kompletter Swift-Lauf nicht grün: 231 Tests, 95 übersprungen, 34 Fehlermeldungen; Sandbox verbietet Socket-Binds, HTTP-Test erhält dadurch Port -1. Keine DB-/Race-/Gesamtabnahme behauptet. Vier statische Reviewbefunde behoben und nachgeprüft. Externe Speicher blockieren Rewrap/Abschluss bis bestätigter Adapter vorhanden; CEK-Gleichheit kann der Server nicht beweisen.

Dateien/Prüfungen/Grenzen/Fortsetzung vollständig: `docs/handoffs/P-Rotation.md`, ADR `docs/decisions/0016-rotation.md`. Hauptagent besitzt Backend/Interop/Dokumentation, Browser-Agent pwa, Testagent RotationTests/PrivacyTests; Reviewer nur lesend. Alle Arbeiten im oben genannten Worktree, kein Commit/Push, keine produktive Migration. Nächster Schritt: DB-Befehl aus Handoff außerhalb dieser Sandbox ausführen, danach Privacy-/Browser-Integration. Keine weiteren DB-Ports/-Namen verwendet. Keine laufenden Jobs bei Übergabe.

### P-Rotation: Hold-Testkorrektur nach Nutzer-DB-Lauf (03.11.2026)

Nutzer-DB-Lauf aus `/tmp/rot.log` gelesen: 231 Tests, fünf übersprungen, ein Fehler; Hold-Test erwartete bei fehlendem Pflichtfeld `objects` irrtümlich 422. Gemeinsamer Decoder liefert vertragsgemäß 400 `bad_request` für nicht dekodierbare Pflichtfelder; Server unverändert. `PrivacyTests.swift` prüft jetzt exakt 400+Fehlercode für vier fehlerhafte Bodies sowie nach jedem Fehler unveränderte HPKE-Pakete/Revisionen, Hold-Flag und fehlendes Hold-Audit. Vorhandene leere Liste wird separat mit 409 geprüft; weitere Sicherheits-/Erfolgsprüfungen bleiben erhalten. Zielgerichteter Swift-Lauf `--filter 'Rotation|Privacy'` kompiliert erfolgreich, Exit 0: 18 Tests, 15 mangels DB übersprungen, drei bestanden. Log lokal `/tmp/rotation-hold-fix-build.log`; `git diff --check` sauber. Korrigierter DB-Test lokal nicht ausgeführt. Besitz: PrivacyTests plus STATUS/ARBEITSPLAN/Handoff; Branch/Worktree unverändert feature-rotation, kein Commit/Push, keine laufenden Jobs. Nächster Schritt: Nutzer führt korrigierten DB-Test erneut aus; Details `docs/handoffs/P-Rotation.md`.

### P-Rotation: vier Astra-Befunde korrigiert (03.11.2026)

Codex, alleiniger Dateibesitz Backend/PWA/Tests/Dokumentation im Worktree/Branch feature-rotation. Rewrap/Hold: explizit 64 MiB Bodylimit; echte TCP-Integration über 16 KiB ergänzt. Recovery und Zugangsreparatur active/retiring per kid; Wiederaufnahmetest nach Verlust beider Zugänge ergänzt. Browser: stabile Kopien, am Lock registrierte Operationspuffer samt Generationsprüfung, synchrone Löschung/finally/Unmount, neuer Wrap wird geöffnet und CEK verglichen. ADR 0016 und `handoffs/P-Rotation.md` fortgeschrieben. Swift `build --build-tests` mit lokalen Modulcaches erfolgreich; PWA 71/71 Vitest, check 0/0, lint/build erfolgreich, Diffprüfung sauber. Swift-/DB-Tests ausdrücklich nicht ausgeführt; Docker nicht aufgerufen. Die zwei neuen DB-/TCP-Tests sind nur kompiliert. Keine Commits/Pushes/Migrationen, keine laufenden Jobs. Nächster Schritt: neue DB-/TCP-Tests außerhalb dieser Session ausführen; Befehle und Grenzen im Handoff.
Deploy-Branch (03.11.2026): Branch `deploy` (Swarm + Compose, Setup-/Update-/Backup-/Restore-Skripte, `docs/BETRIEB.md`) per Codex gebaut und gepusht; kein Caddy, TLS durch externen Reverse Proxy, MariaDB extern, alles per ENV (`*_FILE` über `deploy/docker-entrypoint.sh`, jetzt im Image). Quelle der Wahrheit der Deploy-Dateien ist `main` (Verzeichnisse `deploy/`, `scripts/`); der Workflow `.github/workflows/deploy-branch.yml` erzeugt den Branch daraus. Geprüft: bash -n, shellcheck, --dry-run, compose/stack config; NICHT geprüft: echter Swarm-/DB-/TLS-Betrieb, Image-Build mit neuem Entrypoint (CI).

## P7/P8 Domainzuordnung und Ereignisstatistik (03.11.2026, feature-domains)

Implementiert, ungecommittet im Worktree `form-backend-domains`: Domain-/API-Host-Adminverwaltung (Kundenrecht, frische Anmeldung, Bestätigung/Revision/Audit), pseudonymer Collector Besuch/Beginn/Abbruch mit Proxy-/Origin-/Hostprüfung und DB-Rate-Limit/Idempotenz, signierter Submit-Kontext im Ingest samt API-Releasebindung, 13-Monats-Aufbewahrung und Adminlöschung mit dauerhaftem Nachweis, Statistik-API und vier PWA-Balken mit Conversion. Schema unverändert. ADR 0015 und vollständige Dateiliste/Übergabe: `docs/handoffs/P7-P8-Domains-Statistik.md`.

Prüfungen: vorgeschriebener `P3B_PORT=33420 P3B_NAME=domains-mariadb ./backend/integration-test.sh --filter Domain` blockiert (Exit2: Docker-Daemon nicht erreichbar). Separater Swift-Build/Testlauf ohne DB Exit0: 13 Fälle, 3 ausgeführt/0 Fehler, **10 DB-Fälle übersprungen**. PWA Lint bestanden, Check 0/0, Vitest 62/62, Build erfolgreich; Playwright durch `listen EPERM ::1:4173` vor Browserstart blockiert. `git diff --check` bestanden. Statische Reviews fanden und korrigierten u.a. Proxyheader-Spoofing (Socketpeer jetzt remoteAddress), fehlende Ingest-Hostreleasebindung und Revision-Wiederverwendung. Keine DB-/Browserabnahme behauptet.

Grenzen: Ereigniszählung benötigt Instrumentierung der Clients/Ansichten und signierten `_statistics`-Besuchskontext; Einsendungen ohne Kontext zählen nicht in der neuen Anzeige, Altstatistik bleibt separat erhalten. Keine Domainverwaltungs-UI, öffentliche Formularauslieferung oder implizite Unicodekonvertierung. Neue Collectorprüfung geschlossen ohne freigegebene Proxykonfiguration; Bestätigung im Mutationsrequest statt separatem Token (ADR). Keine laufenden Jobs; Dateibesitz wieder frei. Kein Commit/Push/Deployment. Nächster Schritt: exakt vorgeschriebenen DB-Lauf und gezielten Playwrightlauf in freigegebener Umgebung ausführen, Zählungs-/Instrumentierungsgrenze und Änderungen reviewen; Details im Handoff. Todolino war mangels verfügbarem Tool nicht erreichbar.

## P6 Ablaufengine ohne Skripte (03.11.2026, feature-engine)

Im Worktree `form-backend-engine` ungecommittet implementiert: Target FormFlow mit strengem azyklischem Vertragsausschnitt, festem Bausteinkatalog (Bedingung/Feldtransformation/Mail/Webhook/Warten/Freigabe/Ende), HPKE-Checkpoints, persistentem Lease/Fence-/Effektledger, menschlichem Resume mit Originalobjektnachweis und einmaligem Freigabeverbrauch. Ingest bindet Lauf atomar an veröffentlichtes Release; leerer Standardgraph erhält bisherigen Mailpfad. Debug Observe maskiert mit 900s-TTL und Clusterwartung; Admin-API für Aufzeichnung und Laufsteuerung, deaktivierte Testzieldefinitionen mit test-target.manage. Schema unverändert. ADR 0017 und vollständige Dateiliste/Übergabe unter `docs/handoffs/P6.md`.

Prüfungen: vorgeschriebener `P3B_PORT=33422 P3B_NAME=engine-mariadb ./backend/integration-test.sh --filter Flow` **Exit 2: Docker-Daemon nicht erreichbar**. Abschließender separater Swift-Build/Testlauf ohne DB mit Filter `Flow|FormIngestTests`: **Exit 0, 52 Fälle, 19 ausgeführt/0 Fehler, 33 DB-Fälle übersprungen**; `git diff --check` bestanden. Keine MariaDB-/SMTP-Abnahme behauptet. Bestehende Dependency-Caches aus Hauptworktree nur lesend kopiert; dort nichts verändert.

Offen: Mailfortsetzung ohne unveränderliches Versandmanifest bleibt gesperrt (Manifest wird noch nicht erzeugt); aktive Testsenken/Testausführung/Korrelationsfilter nicht freigegeben; harte Knotenzeitlimits/Isolation fehlen. Webhook-Netzwerkdispatcher liegt im separaten Branch, hier ausschließlich Outbox. Editor, Skripte, Schleifen/Teilabläufe außerhalb des implementierten Minimalausschnitts. P6 ist damit noch nicht vollständig abgenommen. Nächster Schritt: vorgeschriebenen DB-Lauf mit Docker ausführen, Fehler beheben und unabhängiges Resume-/Krypto-/Fencingreview; Restgrenzen im Handoff. Keine laufenden Jobs, Dateibesitz frei, kein Commit/Push/Deployment. Todolino mangels Tool nicht erreichbar.


## P6 Reviewkorrekturen (03.11.2026, feature-engine)

Nutzerbefunde 1/2/3/5/6/8 ungecommittet behoben: Flow-Resend sperrt Originalrendering; prepared-Effekte/Deliveries wiederverwendbar; dauerhafte SMTP-Annahme gleicht uncertain ab; Lauf-/Fenceprüfung unmittelbar vor Transport nach Queue/Secrets; Freigabe-Timeout reject/fail und Gesamtdeadline in Wartung; Abbruch storniert ready-Webhooks des Laufs; Resume-/Checkpointantworten no-store. Neun Backend-/Testdateien, keine Migration. Details und vollständige Pfade: `docs/handoffs/P6-Reviewkorrekturen.md`.

Prüfung: `swift build --build-tests` mit lokalen Caches, TMPDIR=/private/tmp, --disable-sandbox und --build-system native **Exit 0 (26,26 s)**; `git diff --check` bestanden. **Keine Tests ausgeführt; DB-Tests ausdrücklich nicht ausführen, Docker fehlt.** Initiale Standardbuildversuche durch Sandbox-Schreibpfade blockiert; vorhandene Compilerwarnungen bleiben. Keine DB-/SMTP-Laufzeitabnahme.

Befunde **4 Budgetdurchsetzung** und **7 Sperrreihenfolge Eraser/Checkpoint** ausdrücklich offen (größere gemeinsame Konzepte/Nebenläufigkeitstests erforderlich), in ADR 0017 und Übergabe konkretisiert. Mailmanifest/Flow-Mail-Resume weiterhin gesperrt. Nächster Schritt: gezielte DB-/SMTP-Regressionen nach Auftrag mit Docker und unabhängiges Review, danach separate Pakete für 4/7. Worktree `form-backend-engine`, Branch `feature-engine`, Basis `1fa86bc`; keine laufenden Jobs/Agents, Dateibesitz frei. Kein Commit/Push/Deployment.


## P6 DB-Fehlerkorrektur aus seq2-Lauf (03.11.2026)

Worktree `form-backend-engine`, Branch `feature-engine`, Basis `1fa86bc`; ein schreibender Codex, keine Delegation. Paket: ausschließlich die zwei fehlgeschlagenen FlowIngestTests aus `/tmp/seq2-engine.log`. Log gelesen: Abbruch meldet MySQLError/500 mit unveränderter ready-Outbox; Resend-Test meldet 422 statt 409.

Ursachen und Korrekturen: `FormFlow/FlowStore.swift` schrieb den nicht im Outbox-ENUM enthaltenen Wert `cancelled`, wodurch die gesamte Abbruchtransaktion zurückrollte. Jetzt bestehender Zustand `failed-terminal`, `last_error_code=flow-stopped`, keine nächste Ausführung und Abschlusszeit; weiterhin nur ready-Zeilen des Laufs, ohne Schemaänderung. `FormAdminTests/FlowIngestTests.swift` erwartete ebenfalls den ungültigen Zustand; Assertion auf gültigen Endzustand/Fehlercode/Abschlusszeit angepasst. Der Mailtest übergab eine großgeschriebene Delivery-UUID, obwohl `MailRoutes.lowerUUID` Kleinbuchstaben verlangt; Testeingabe normalisiert, Fehlerantwort in Assertions ergänzt. Die Produktionsvalidierung bleibt unverändert.

Prüfung: `swift build --build-tests` mit den Cache-/Native-Optionen aus `docs/handoffs/P6-Reviewkorrekturen.md` Exit 0; Log `/tmp/seq2-engine-fix-build.log`. `git diff --check` bestanden. Auf Nutzerauftrag keine DB-Tests oder sonstigen Testläufe ausgeführt. Keine Commits, Migrationen oder Veröffentlichungen; vorhandene uncommittete Reviewkorrekturen erhalten. Dateibesitz frei, keine laufenden Jobs.

**Merge offen:** Der angeforderte Merge von main konnte nicht gestartet werden: bereits die Sicherung der lokalen Änderungen mit `git stash push -u` scheiterte am Sandbox-Schreibverbot für `form-backend/.git/worktrees/form-backend-engine/index.lock` (außerhalb des erlaubten Worktrees). Kein Stash erzeugt, kein Mergezustand angelegt. Nächster Schritt: main in schreibberechtigter Umgebung ohne Commit mergen, dabei in STATUS/ARBEITSPLAN beide Seiten behalten und die vorhandenen lokalen Änderungen sichern/erhalten; danach Build wiederholen und die beiden DB-Tests durch den Nutzer ausführen lassen. Der vorliegende Build belegt nur den feature-engine-Stand vor diesem Merge.
Codex-Jobs 03.11. (Stand Nachmittag): Webhook-Befundbehebung `task-mw0dqfwf-ilef4u` (feature-webhooks), Rotation `task-mw0ewah8-3vlj52` (feature-rotation), Review Domains `task-mw0f0mms-s927dq`, neu: Ablaufengine `task-mw0f6b5i-d5gw3w` (feature-engine, ADR 0017), MCP/Tokens `task-mw0f6bcv-iz8a0d` (feature-mcp, ADR 0018), Externe Speicher `task-mw0f6bz9-gtmbro` (feature-storage, ADR 0019). Migration (feature-migration) wartet auf Review. Alle Worktrees liegen neben dem Repo (`../form-backend-*`). Domains und Platzierung sind auf main.

## Reviewkorrekturen Domains/Ereignisstatistik (03.11.2026, main)

Vier Nutzerbefunde direkt im Hauptverzeichnis behoben, ungecommittet: Einsendungs-Fallback auf Legacy-Eingänge vor 03.11.2026 00:00 UTC begrenzt (13 Kalendermonate, dauerhafte Löschgrenze über manuelle deletion_records, auch leere Löschung); neue Absenden-/Conversionzählung ausschließlich über Submit-Ereignis; Retention bis 50 Batches à 200 bzw. 20 Sekunden mit Restprüfung und erneuter Scheduler-Ausführung nach höchstens 60 Sekunden; Collectorbudgets erst nach Proxy-/Host-/Origin-/Bindungs-/Inhaltsprüfung, getrenntes Ungültig-Budget je Socketpeer, auch OPTIONS.

Tests ergänzt: DELETE→GET bei erhaltenen Einsendungen inklusive Legacy/Leerlöschung/Rückdatierung; zwei echte Ingest-Einsendungen eines Besuchs mit API-Conversion und echter Inhaltslöschung; 605 fällige Ereignisse, Ein-Batch-Limit und anschließende Leerung; ausgeschöpftes Ungültig-Budget blockiert gültigen POST/OPTIONS-Verkehr nicht. ADR 0015 aktualisiert. Dateiliste/Vertrag/Grenzen: docs/handoffs/Review-Domains-Statistik-Korrekturen.md.

Prüfungen: finaler gezielter Swift-Build/Test erfolgreich (Exit 0): CLANG_MODULE_CACHE_PATH="$PWD/backend/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/backend/.build/ModuleCache" swift test --package-path backend --scratch-path backend/.build --cache-path backend/.build/cache --manifest-cache local --disable-sandbox --build-system native --filter Domain. 16 Fälle, davon 3 ausgeführt/0 Fehler, 13 DB-Fälle mangels DB-Umgebung übersprungen. Bestehende Compilerwarnungen außerhalb dieses Pakets (u.a. KeyRoutes-Captures, native Builder deprecated). git diff --check bestanden.

Vorgeschriebener DB-Lauf P3B_PORT=33420 P3B_NAME=domains-mariadb ./backend/integration-test.sh --filter Domain scheiterte vor Teststart mit Exit 2: Docker-Daemon nicht erreichbar. Nutzer führt diesen Lauf aus; keine erfolgreiche DB-Verhaltensprüfung behauptet. Kein Commit/Push/Deployment, keine Schemaänderung. Ein schreibender Codex, keine Delegation, keine laufenden Jobs, Dateibesitz frei. Todolino mangels verfügbarem Tool nicht nutzbar.

## P8 Webhooks — in Arbeit (03.11.2026)
Worktree `form-backend-webhooks`, Branch `feature-webhooks`; API, Ingest-Vormerkung, Worker und HTTP-Transport werden als abgegrenztes Paket implementiert (Dateibesitz ARBEITSPLAN, Vertrag ADR 0013). SecretStore speichert 32-Byte-Ed25519-Seed verschlüsselt; Schema bleibt unverändert. Abgelaufene Leases werden `uncertain`, Empfänger deduplizieren Delivery-UUID. Todolino-Werkzeuge sind in dieser Session nicht verfügbar; Repository dokumentiert den Stand. Testjob: isolierter Container `webhooks-mariadb`, Port 33418, Log `/tmp/p8-webhook-test.log`; keine Commits/Pushes.

## Webhooks: Astra-Reviewkorrekturen (03.11.2026)
Worktree `form-backend-webhooks`, Branch `feature-webhooks`; Änderungen ausdrücklich **uncommittet**. Alle Dateien dieses Korrekturpakets beim Codex-Hauptagenten, keine Teilagents/laufenden Jobs. Umsetzung: aktive Endpointquoten 5/Formular und 20/Kunde (ENV), atomare Rückstaugrenze 1000/Kunde (`ready`+`leased`, ENV), Überlauf als `failed-terminal`/`backlog` bei weiterhin angenommener Einsendung. Gemeinsame Kundenzeilensperre und aktuelle sperrende Zählungen verhindern Quotenrennen. Worker wählt Round-Robin, maximal 20/Kunde und 100/Pass, sendet in Wellen bis acht parallel; globaler Lock nur während Claim, ohne Netzverkehr. DNS über gemeinsamen HostGuard mit vier dedizierten NIOThreadPool-Threads, 3-s-Deadline und Sättigungsablehnung; blockierende Restaufrufe behalten ihren Platz. Anlage meldet DNS-Timeout als 422. Finale Zustandsänderung prüft Lease-Ablauf im UPDATE mit nach der Zeilensperre frisch gebundener Zeit; abgelaufene eigene Claims werden `uncertain`. Vertrag/Begründung: ADR 0013.

Dateien: `backend/Sources/FormWebhooks/{WebhookLimits,WebhookDispatcher,WebhookHTTP}.swift`, `FormAdmin/WebhookRoutes.swift`, `FormIngest/IngestRoutes.swift`, `FormMail/HostGuard.swift`, `backend/Package.swift`; Tests `FormAdminTests/{WebhookTests,WebhookHTTPTests,AdminFixture}.swift`. Keine Schemaänderung/Migration. HostGuard-Begrenzung gilt auch für Mail-/Deploy-Auflösung.

Prüfstand: Swift-Package inklusive App und aller Testtargets kompiliert mit nativem Builder. Zwei ausführbare Tests (Fake-DNS-Deadline/Sättigung samt 422-Meldung, ungültige/gesperrte Ziele) bestanden. Zwei HTTPS-Tests konnten ihren lokalen Server wegen Sandbox `bind: Operation not permitted` nicht starten; kein fachliches Testergebnis. Docker-Daemonprobe Exit 1, daher DB-Tests nicht ausgeführt. Neue DB-Fälle: Formular-/Kundenquote und Reaktivierung, terminaler Rückstau einschließlich angenommener echter Ingest-Anfrage, faire parallele Zustellung bei zwei Kunden und 20er-Kappe, künstliche Zeilensperrwartezeit über Lease-Ende, Endpoint-Löschung bei offenem Send. `git diff --check` erfolgreich. Keine Produktionsreife/DB-Abnahme behauptet.

Nächster Schritt durch Nutzer: mit Standardquoten (keine abweichenden FORM_WEBHOOK_MAX_*-Werte) `P3B_PORT=33418 P3B_NAME=webhooks-mariadb ./backend/integration-test.sh --filter Webhook` ausführen. Danach insbesondere MariaDB-Lock-/Fensterfunktionsverhalten und Race-Tests bewerten. Parallelität acht gilt je Dispatcher-Lauf/Replika; terminale Metadaten wachsen weiterhin gemäß Ereigniszahl und benötigen spätere Aufbewahrungsbereinigung. Keine gestarteten Container, Commits oder Pushes in dieser Korrektursession.
## SDKDeploy-Hänger (03.11.2026, fix-sdkdeploy-hang)

Ungecommitteter Fix im Worktree `form-backend-hang`, Basis main/ef1a6cb: statisch belegte Kombination aus veraltetem Fake-FTP-Datenkanal nach Upload und unbegrenztem FTP-Clientwarten auf EOF nach 226 behoben. Zusätzlich verschachtelte Poolreservierungen Scheduler → Deploy → Secret durch gemeinsame SQL-Session ersetzt. Netzwerk-/Server-Zeitlimits, Einverbindungstest und Prozess-Watchdog (900s, FORM_TEST_TIMEOUT_SECONDS) ergänzt. Swift-Build erfolgreich; gezielte 14 Tests: 5 bestanden, 7 durch gesperrtes Loopback-Bind fehlgeschlagen, 2 übersprungen; Docker-Socket ebenfalls gesperrt. Keine Reproduktion/FTP-/DB-Abnahme behauptet. Shellsyntax, Watchdog inkl. KILL und Diffprüfung bestanden. Kein Commit, keine laufenden Jobs, Dateibesitz frei. Vollständige Ursachen, Dateien, Restrisiken und nächste Befehle: `docs/handoffs/Fix-SDKDeploy-Hang.md`. Nächster Schritt: gezielter echter DB-/FTP-Lauf, danach serielle Gesamtläufe in freigegebener Umgebung.

## P8 externe Speicher (03.11.2026, feature-storage)

Implementiert, ungecommittet im Worktree `form-backend-storage`: ObjectStore DB/S3/SFTP (eigene SigV4, TLS, HostGuard, SFTP-Pinning), durable Chiffrat-Spool mit prepared/failed→ready und minütlichem Wiederanlauf, Kunden-/Formularrichtlinien und Probe-/Admin-API, Ingest-Platzierung nach Originalanhanggröße, DB-/externes Lesen samt Hashprüfung, zweiphasige Löschabsicht und bestätigte externe Löschung vor Zeilen/Beleg. ADR 0019; API-/Betriebsvertrag `contracts/data/externe-speicher.md`; Dateiliste und Fortsetzungsstand `docs/handoffs/P8-Speicher.md`.

Prüfung: Swift-Gesamtbuild erfolgreich. Gezielter Abschlusslauf 9 Fälle: 5 bestanden, 4 DB-Fälle übersprungen, 0 Fehler. Neue vollständige Auswahl 11 Fälle: 5 bestanden, 4 DB-Fälle übersprungen, 2 Transportfälle durch `bind EPERM` fehlgeschlagen. Vorgeschriebener `P3B_PORT=33424 P3B_NAME=storage-mariadb ./backend/integration-test.sh --filter Storage` zweimal Exit2 (Docker-Daemon nicht erreichbar). Diff-Whitespace und Schema-Parität bestanden. **Keine DB-/Transportabnahme oder Produktionsreife behauptet.**

Grenzen: unversionierte S3-Buckets, kein Sessiontoken/Endpoint-Basispfad; SFTP HEAD liest begrenzt. Neue Spooltabelle benötigt vor Bestandsrollout additive Migration und abgestimmten Umgang mit Baselinechecksummen. Keine PWA-UI/Bestandsverlagerung. Keine laufenden Jobs; Dateibesitz frei. Kein Commit/Push/Deployment. Nächster Schritt: vorgeschriebenen DB-/Socketlauf in geeigneter Umgebung und Crash-/Konkurrenzprüfungen ausführen; Details im Handoff. Todolino-Tools nicht verfügbar.

### P8-Speicher Nachkorrektur nach Nutzerlauf (03.11.2026)

Nutzer meldete Docker/MariaDB-Gesamtlauf mit 246 Tests und 3 Fehlern (1 Schemaanzahl, 2 falsche 403-Erwartungen). Ursachen korrigiert: SplitterTests erwartet bewusst 74 Tabellen wegen `storage_uploads`; StorageRoutes übergibt mandantengebundene Existenzprüfungen an `authorize(... exists:)` (GET/PUT/Probe, PUT erneut transaktional). StorageLifecycleTests unterscheidet jetzt Konto ohne Systemgrant → 404, Systemgrant ohne system.manage → 403 bei existierender Ressource, fehlendes Ziel → 404 auch mit Systemrecht. Die Tabelle bleibt für wiederholbare Uploads nötig; ADR 0019 dokumentiert ausdrücklich: additive DDL-Vorlage vorhanden, aber **kein unterstützter Upgrade-Pfad für bereits migrierte Baselines** wegen Checksumprüfung des bisherigen MigrationRunner.

Eigene Prüfung: Swift-Gesamtbuild erfolgreich; gezielt `SplitterTests|StorageLifecycleTests`: Exit0, 8 Fälle, 4 Splittertests bestanden (inkl. 74 Tabellen), 4 DB-Fälle übersprungen. Dockerprüfung weiter blockiert (`ENV: docker daemon not reachable`, Skript Exit2); neue Rechtefälle nicht als DB-bestanden behauptet. `git diff --check` und Schema-Parität bestanden. Worktree/Branch unverändert feature-storage, kein Commit/Push/Migrationslauf; keine laufenden Jobs, Dateibesitz frei. Nächster Schritt: Nutzer-Gesamtsuite oder gezielt SplitterTests/StorageLifecycleTests erneut mit MariaDB ausführen; Bestandsupgrade vor Rollout separat implementieren.

## Öffentliche Dokumentation main-Abgleich (03.11.2026)

Paket auf Branch `site-update`, Basis main `8444a65`, abgeschlossen; ein schreibender Codex, keine Delegation. Besitz: acht HTML-Quellen in `site/content/` (index, architektur, benutzung, einrichtung, entwicklung, sdk, sicherheit, api), entsprechende Ausgaben in `site/dist/`, dieser Status und ARBEITSPLAN. `status.html` in Quelle und Ausgabe bytegleich zu HEAD belassen. Keine laufenden Jobs; Dateibesitz frei. Keine Commits, Veröffentlichung, Deployments oder Migrationen.

Ergebnis: öffentliche Inhalte gegen vorhandene main-Routen, SDK-Code, Deploy-Vorlagen und relevante Entscheidungen abgeglichen. ADR 0011/0012/0013/0015/0019 aufgenommen, alte P5-Lücken korrigiert, Caddy-/mitgelieferte-DB-Anleitung ersetzt. Rotation/Engine/MCP/Altdatenmigration ausdrücklich nicht als auf main vorhanden dargestellt. Offene Speicherreviews, fehlender Bestandsupgrade-Runner, nicht freigegebene SDK-Automatik und fehlende Betriebsabnahme benannt. Historische README-/ADR-/Handoff-Zwischenstände nicht ungeprüft als aktuellen Implementierungsstand übernommen.

Ausgeführt: `node site/build.mjs` ohne `--base` (9 Seiten, 404-Basis `/`), `node site/check.mjs` (9 Seiten, Links/Anker OK), `git diff --check` erfolgreich; Statusdateien byteweise gegen HEAD geprüft. Keine lokalen Benutzerpfade in den acht Quellen. Anwendungstests, echte Deploy-/DB-/Transporttests und visuelle Browserabnahme nicht erneut ausgeführt. Nächster Schritt: redaktioneller Review des Diffs; technische Betriebs-/Sicherheitsabnahmen bleiben separate Pakete.

## P8 MCP und API-Tokens (03.11.2026, feature-mcp)

Im Worktree `form-backend-mcp` ungecommittet implementiert: persönliche API-Tokens (einmalige Ausgabe, SHA-256, Bereich/Scopes als Schnittmenge aktueller Rechte, Ablauf/Widerruf, Audit/letzter Gebrauch, DB-Limits), ausdrücklich ausgewählte Konfigurations-/Entwurfsrouten mit Bearer und strikt sitzungsgebundene menschliche Aktionen, MCP POST/JSON mit fünf Werkzeugen sowie PWA `/api-tokens`. ADR `0018-mcp-tokens.md` und vollständige Dateien/Verträge/Grenzen: `docs/handoffs/P8-MCP.md`. OAuth ist vertraglich nicht v1-verbindlich und bleibt dokumentiertes Restpaket; keine Altcredentials übernehmen, kein Publizieren/Entschlüsseln durch Tokens.

Prüfungen: vorgeschriebener Docker-Lauf auf Port 33423/Container `mcp-mariadb` Exit2 (Daemon nicht erreichbar). Swift-Build und Tokenfilter Exit0: 8 Fälle, **7 DB-Fälle übersprungen**, 1 ausgeführt/bestanden. PWA Lint/Check 0/0, Vitest 64/64, Build bestanden. Playwright vor Browserstart blockiert (`listen EPERM ::1:4173`); `git diff --check` bestanden. Kein DB-/Browser-/Produktionsnachweis, kein unabhängiges Review. Keine Schemaänderung, kein Commit/Push/Deployment. Dateibesitz frei, keine laufenden Jobs. Nächster Schritt: exakt vorgeschriebenen DB-Lauf und `pwa/e2e/tokens.spec.ts` in freigegebener Umgebung ausführen, Sicherheitsreview und Zielclientabgleich. Todolino nicht als Werkzeug verfügbar.

## P8 MCP – vier Reviewbefunde korrigiert (03.11.2026, feature-mcp)

Im Worktree `form-backend-mcp` ungecommittet: IP-Budgets aus echtem remoteAddress (Proxyheader nur über explizit vertrauenswürdigen Proxy); MCP-Dispatch übernimmt intern geprüfte Identität ohne doppeltes IP-/Tokenbudget, authentifizierte Anfragen ohne Socketadresse nur pro Token; Entwurfsänderungen mit atomarem Token-/Ziel-/Revisions-/Ergebnisaudit und getrennten Fehlerereignissen; Eigenwiderruf nach Eigentumsprüfung/frischer Sitzung auch ohne token.manage. Details/Dateibesitz und Vertrag: ADR 0018, `docs/handoffs/P8-MCP.md`.

Prüfungen: Swift-Build einschließlich aller Tests Exit 0; ausschließlich DB-freie ForwardedForTests ausgeführt (2/2 bestanden); diff --check bestanden. Neue DB-Regressionstests für Budgettrennung/-zählung, Auditrollback und Eigenwiderruf geschrieben/kompiliert, auf ausdrücklichen Auftrag **nicht ausgeführt** (Docker nicht verfügbar). Keine Schemaänderung, kein Commit/Push/Deployment. Dateibesitz frei, keine laufenden Jobs. Nächster Schritt: `P3B_PORT=33423 P3B_NAME=mcp-mariadb ./backend/integration-test.sh --filter Token` in Docker-Umgebung ausführen, danach verbleibende Browser-/Zielclientabnahme und unabhängiges Gesamtreview.

## P11-B Systemeinstellungen (03.11.2026)

Auf `feature-settings` im Worktree `form-backend-settings` ungecommittet umgesetzt:
zentrale Registry, Systemwerte mit ENV > DB > Default, ENV-Sperren, Admin-API mit
`system.settings`/frischem Login/CSRF, atomare Revision und Audit ausschließlich mit
Schlüsselnamen, PWA-Einstellungen mit Quellen und Neustartpflicht. Live verdrahtet:
MCP-Limit (neu 60/min pro Token) und drei bestehende Webhookquoten. Andere registrierte
ENV-Werte werden beim Neustart übernommen. Keine erfundenen Aufbewahrungs-/Speicher-
ENV-Parameter; Bootstrap bleibt ENV. ADR 0021, vollständige Übergabe `docs/handoffs/P11-B.md`.

Prüfungen: Swift-Build einschließlich Testtargets erfolgreich; 24 ausgewählte
DB-freie Swift-Tests bestanden (FormCore, Systemrecht, Tokenrechte). PWA check,
66 Vitest-Tests, Build und lint bestanden. Playwright-Einstellungsseite versucht,
aber Preview-Listener mit EPERM blockiert. DB-Tests ausdrücklich nicht ausgeführt.
DDL-Dateien identisch, diff --check sauber. Kein Commit/Deployment. Bestandsupgrade
und explizite Rechtevergabe, DB-/Nebenläufigkeitsabnahme sowie Browserlauf und
unabhängiges Sicherheitsreview offen. Dateibesitz frei nach Abschluss, keine Dienste.
## P11-A Listener und Deploy (03.11.2026, feature-listener)

Ungecommittet im Worktree `form-backend-listener`, Basis `f5d0d90`: zwei HTTPServer mit strikt
getrennten Registrierungen, einer Application/DB-Pool/Dienstinstanz. Öffentlich 8080
Ingest/Collector/MCP/Metadaten und Healthz, intern 8081 PWA/Admin/Readiness/Healthz;
Ingest/Collector/MCP intern 404. Öffentliches Dashboard standardmäßig aus, optional mit
verpflichtender Hostliste und Host-/Origin-/CSRF-Prüfung; Proxy-Vertrauen je Listener.
Legacy FORM_HTTP_PORT ist interner Fallback. Deploy: zwei Aliasse, interne Readinessprüfung,
optionale Veröffentlichungen je Port. ADR 0020 und `docs/handoffs/P11-A.md` enthalten Vertrag,
Dateibesitz, Fortsetzungsbefehle und Grenzen. Kein OAuth, keine Schemaänderung.

Prüfungen: Build einschließlich aller Tests erfolgreich; 24 DB-freie Swift-Tests bestanden
(davon 3 ListenerTests). Deploy-Vertragsprüfung mit Kommando-Doubles und daemonfreiem CLI-
Rendering einschließlich je vier neuer Swarm-/Compose-Portkombinationen bestanden;
Shellsyntax/ShellCheck/Diffprüfung bestanden. DB-Tests ausdrücklich nicht ausgeführt,
keine Docker-/Proxy-Laufzeitabnahme. Kein unabhängiges Sicherheitsreview, kein Commit/Push/
Deployment. Ein schreibender Codex, Dateibesitz frei, keine laufenden Jobs. Nächster Schritt:
Sicherheitsreview und echte Zwei-Port-/DB-/Proxy-Abnahme, danach P11-B/P11-E.
## P7-F SDK-Failover (03.11.2026, feature-failover)

Im Worktree `form-backend-failover` ungecommittet umgesetzt: SDK 0.3.0 mit signierter geordneter Endpunktliste aus der SDK-Zugangsdaten-Ausgabe, standardmäßig 10 s Netzwerkbudget/3 Versuche, identischen Wiederholungsbytes und Wechsel nur bei Netzfehler/Timeout/Abbruch/502–504. Alle 4xx einschließlich 429 und alle 500 terminal. Bestehende API-Hostverwaltung erlaubt Backupzuordnung ohne Schemaänderung; Ausstellung prüft aktive Formularallowlist und gleiche Releasebindung. Submit-Signatur ist hostunabhängig; bestehende Ingest-/Origin-/Collectorregeln unverändert. Vertrag ADR 0020; vollständige Dateien, Befehle, Risiken und Fortsetzung: `docs/handoffs/P7-F.md`.

Prüfungen: PHP-SDK 120 und cURL-Policy 47 Prüfungen bestanden; PHP-Syntax erfolgreich; Swift-Build einschließlich Tests erfolgreich, 14 gezielt DB-freie Swift-Fälle bestanden; PHP/Swift-Krypto-Interop nach Swift-Export vollständig bestanden; Diffprüfung bestanden. Neue DB-Regressionen nur kompiliert, ausdrücklich nicht ausgeführt (Docker nicht verfügbar). Keine echte Netz-/Proxyabnahme, kein unabhängiger Review. Keine laufenden Jobs, Dateibesitz frei, ein Codex ohne Delegation, kein Commit/Push/Deployment. Nächster Schritt: Domain-DB-Lauf gemäß Handoff, anschließend echte TLS-/Proxy-Failoverabnahme.

## P9 Retry-Nachkorrektur (03.11.2026, feature-migration)

Log `/tmp/seq3-migration.log`: 7 Migration-DB-Tests, nur Retry-Statusprüfung fehlgeschlagen (`failed` statt `verified`); Abschlusszeitprüfung ohne Fehler. Ursache: falsches offenes Review-Issue beim Feldabgleich durch unterschiedliche Schlüsselsortierung in JSONSerialization/JSONEncoder. `Transform.swift` vergleicht nun dekodierte Feldwerte einschließlich NULL statt JSON-Bytes. Der Abschluss-UPDATE in `LegacyImporter.swift` war bereits bedingungslos und bleibt unverändert. Retry-Test um importierte Feldzeile, initiales `verified` und null offene Issues ergänzt. Vertrag: ADR 0014 Reviewkorrekturen/Nachkorrektur.

Paket/Dateibesitz: ein Codex, ausschließlich Transform.swift, MigrationTests.swift, ADR 0014, P9-Handoff, STATUS/ARBEITSPLAN; Worktree `form-backend-migration`, Branch `feature-migration`, kein Commit/Push. Prüfergebnis und nächste Aktion siehe abschließender Prüfvermerk im P9-Handoff; keine DB-Tests ohne Docker.

P9 Retry-Prüfabschluss: `swift build --build-tests` mit lokalen Caches, `--disable-sandbox --build-system native` und `TMPDIR=/private/tmp` erfolgreich (Exit 0, Tests kompiliert/verlinkt). Isolierter Inhaltsvergleich geprüft; `git diff --check` erfolgreich. Keine DB-Tests ausgeführt. Dateibesitz frei, keine laufenden Jobs, nichts committet. Nächster Schritt bleibt der Migration-DB-Lauf beim Nutzer; exakter Buildbefehl/Grenzen im P9-Handoff.

## P6 seq3-Ingest/Webhooks nach main-Merge (03.11.2026)

Paket auf `feature-engine` im Worktree `form-backend-engine` abgeschlossen, ungecommittet; ein schreibender Codex, keine Delegation. Alle sieben Assertions aus `/tmp/seq3-engine.log` einzeln geprüft: sechs Folgefehler durch doppelte Standard-/Flow-Outboxeinreihung, eine falsche Text-Erwartung beim bereits korrekten Mail-409. `IngestRoutes.swift` reiht Standard-Webhooks jetzt ausschließlich beim Standardplatzhalter ein; eigene Flows steuern sämtliche Zustellungen selbst, auch ohne Webhook-Baustein. Regel/Begründung in ADR 0017. `FlowIngestTests.swift`: Mailassertion auf öffentlichen Fehlervertrag korrigiert; zusätzliche Regression zu Placeholder/Flow-ohne-Webhook, inaktiven Endpoints und Replay. Keine Aufweichung der bisherigen Queue-/Abbruchassertions.

Prüfung: `swift build --build-tests` mit lokalen Caches und nativem Builder Exit 0 (17,28 s), Log `/tmp/seq3-engine-fix-build.log`; `git diff --check` bestanden. Auf ausdrücklichen Auftrag keine Tests/DB-Läufe. Keine Schemaänderung, Commits, Migrationen oder Deployments; keine laufenden Jobs, Dateibesitz frei. Einzelbefunde, Dateibesitz, Grenzen und nächster Befehl: `docs/handoffs/P6-Seq3-Ingest-Webhooks.md`. Nächster Schritt durch Nutzer: DB-Lauf `P3B_PORT=33422 P3B_NAME=engine-mariadb ./backend/integration-test.sh --filter Flow`. Bestehende Lücken (Budgets, Sperrreihenfolge, Flow-Rückstaugrenze) bleiben offen. Der frühere Hinweis „Merge offen“ ist durch den vom Nutzer bestätigten main-Merge überholt.

## Feature-Inventur Altbackend (03.11.2026)

Paket auf Branch `parity-inventory`, Checkout `form-backend-parity`, Basis `2374ea0c28109164e41ae8ce8023c4e06817e7db`: `docs/paritaet/featureliste-alt.md` und `abnahme-skript.md` erstellt. Ein schreibender Codex, keine Delegation. Ziel/Vertrag: erneut erhobene nutzersichtige Alt-Funktionen mit Altbelegen, im aktuellen Checkout gesuchten Gegenstücken, Status und konkreter Abnahme; Altprojekt ausschließlich lesend, Secrets/Kundendaten ausgeschlossen. 151 Punkte: 53 vorhanden, 62 teilweise, 33 fehlt, 3 bewusst entfallen. Code-Status ist kein Laufzeitnachweis. Priorisierte Fehlstellen und Muss-Teilfunktionen stehen im Inventar.

Wesentliche Ersatzlücken: Turnstile/Malwarescanner, TOTP inklusive Verwaltung/Secretablage (kein beschlossener Entfall gefunden), Passwortwechsel/Kontosperre, Alarm-/Fehleransichten, OAuth und MCP-Statistikwerkzeuge, fertiger lokaler Export/Betroffenensuche. 39 Migrationsdateien erfasst (025 fehlt im Alt-Dateibestand), mit FA-IDs verknüpft. Nachweisgrenze: fünf macOS-dataless-Dateien konnten trotz Leseversuch nicht neu gelesen werden: WebhookOutboxEinsteller, Migration 029, UI Anmeldeprotokoll/Betroffenenrechte/Passkeylogin. Vorarbeit und lesbare Aufrufer sind ausdrücklich als Ersatzbeleg abgegrenzt; daher kein uneingeschränkter Vollständigkeitsnachweis. Zwischenzeitlich nachgeladene UploadPipeline/WebhookHttpClient/Migration 013/Konfigurations-UI wurden gelesen.

Prüfungen: 151 fortlaufende eindeutige IDs, Tabellenstruktur, Altpfad-/Zeilenbereich, Gegenstückpfade und Fehlstellenreferenzen statisch geprüft; Pythonblock kompiliert, Init mit 151 OFFEN, Record/Reset und Ablehnung unbeschlossenen ENTFALLEN ausgeführt; Summary Exit 1 für offene Abnahme erwartungsgemäß. Keine HTTP-/Browser-/DB-/Anwendungstests ausgeführt. Alt-Leseversuche abgebrochen, keine Anwendung oder Migration gestartet, kein Commit/Deployment. Dateibesitz bei Übergabe frei. Nächster Schritt: fünf fehlende Erstquellen lokal bereitstellen/nachprüfen, Muss-Lücken schließen oder entscheiden und das Gerüst gegen isolierten Neubau durchführen.

## P11-E MCP-OAuth (03.11.2026, feature-oauth)

Uncommittet auf Basis `4075e49` im Worktree `form-backend-oauth` implementiert: öffentliche Discovery,
DCR und Tokenendpunkt; interne Autorisierung/Widerruf; PWA-Consent/Grant-/Clientverwaltung, PKCE S256,
60-s-Codes, 15-min-Access, rotierende Refreshfamilien mit Replaywiderruf, Live-Rechte und Audit.
Vertrag/Dateibesitz/Schema/Betrieb: ADR 0022 und `docs/handoffs/P11-E.md`. Ein Codex, keine Delegation.
Registry/SystemSettings aus vorhandenem `feature-settings` übernommen; keine Settings-PWA übernommen.
Neue Consent-Tabelle plus Grantbereich/CHECK/Index im Schemaentwurf, kein Bestandsupgrade ausgeführt.
DB-Tests geschrieben und nur kompiliert; Docker nicht verfügbar, keine DB-Tests gestartet.
Kein Commit/Push/Deployment. Finaler Prüfstand folgt direkt unten.

P11-E final geprüft: Swift-Build einschließlich sämtlicher Tests Exit 0; 34 ausgewählte DB-freie
Swift-Tests bestanden (5 OAuthUnit, Listener/Core/Splitter/ForwardedFor und TokenBoundary).
Acht neue OAuth-DB-Integrationstests nur geschrieben/kompiliert, ausdrücklich nicht ausgeführt.
PWA `check`: 0 Fehler/0 Warnungen; 12 gezielte Tests bestanden; Build, ESLint/Prettier der geänderten
PWA-Dateien, `bash -n backend/db/check.sh` und `git diff --check` Exit 0. Kein Docker-/DB-/Browserlauf,
kein unabhängiges Review, keine echte Claude-/ChatGPT-Abnahme. Dateibesitz frei, keine laufenden Jobs.
Nächster Schritt: Review und die im Handoff aufgeführten DB-/Browser-/Clientprüfungen; für Bestand
separater versionierter Upgradepfad nötig. Kein Commit oder Deployment.
## P11-G — Listenerabhängiger Zweitfaktor (03.11.2026)

Im Worktree `form-backend-auth`, Branch `feature-auth`, ungecommittet umgesetzt.
Intern standardmäßig UV-Passkey allein, ENV `FORM_INTERNAL_SECOND_FACTOR=1`
aktiviert Zweitfaktor; öffentlich immer Passkey plus Passwort. Serverseitige
Listenerpolicy und getrennte v2-Sitzungshashdomänen, keine Host-/Headerentscheidung.
Fresh-Login 5 min bleibt; optionale interne Startpasswörter, eigene Passwortsetzung
unter Konto, PWA/Deploy/Verträge angepasst. Bewusste Schutzabschwächung und
Gegenmaßnahmen: ADR 0022. Vollständige Dateien/Vertrag/Prüfungen und Befehle:
`docs/handoffs/P11-G.md`.

Swift-Testbuild erfolgreich, 25 DB-freie Swift-Tests, PWA Check/Lint/80 Vitest/Build,
YAML-/Shell-/Diffprüfungen bestanden. DB-Tests ausdrücklich nicht ausgeführt;
Playwright am Preview-Listen mit EPERM blockiert. Gesamt-Auth-Vertragsvalidator
scheitert am unveränderten Permission-Enum/DDL-Katalogabgleich (Zeile 233).
Ein schreibender Codex, Dateibesitz frei, keine Jobs/Delegation/Commits/Deployments.
Nächster Schritt: Docker-Integrationstests und Browserfälle aus dem Handoff,
danach unabhängiger Sicherheitsreview; Katalogbefund separat beheben.
## P12-B — Browser-Zugriffsautomatik (03.11.2026, Teilstand)

Auf `feature-keys` / Worktree `form-backend-keys` ungecommittet: Login-PRF für neue Kontowraps, automatische Kundeneinrichtung vor Formularanlage, wiederaufnehmbarer Hintergrund-Rewrap bestehender Rotationen mit CAS/Hold/Sperrabbruch, Rohschlüsseleingabe aus Einsendungen entfernt, technische Panels nach Konto/Erweitert verschoben. Shell-/UI-Fundament von feature-ui unverändert. Ein Codex, Dateibesitz frei, keine Jobs. ADR 0024 und `docs/handoffs/P12-B.md` sind maßgeblich.

**P12-B bleibt unvollständig:** kontoweiter Setupcode samt PRF-losem Login und Codeerneuerung fehlen (bisher nur Kundengenerations-Recovery); Rotationsbeginn/Zugangsreparatur weiterhin manuell, keine dauerhafte Hold-Auftragswarteschlange. Registrierung/Seitenreload lösen noch keine vollständige autonome Wiederaufnahme aus. Kundencode ist ausdrücklich nur Zwischenstand, keine Erfüllung der einmaligen Kontorecovery. Keine Backend-/Schemaänderung; Baseline allein ist kein Bestandsupgrade. Nächster Schritt: Kontorecovery-Vertrag/API/versionierten Upgradepfad umsetzen, dann übrige Automatik und echte Browserabnahme.

Typprüfung, Lint, 83 Vitest-Tests/17 Dateien, Build und diff --check bestanden; Playwright vor Teststart durch `listen EPERM ::1:4173` blockiert. npm ci scheiterte an DNS, danach lokale Abhängigkeiten aus Hauptcheckout mit identischer Lockdatei kopiert. Keine Swift-/DB-/Docker-Tests, kein unabhängiges Review, kein Commit/Deployment. Todolino nicht extern aktualisiert (kein Tool verfügbar).
## P12-A Schritt 1 (03.11.2026)

Auf `feature-ui` im Worktree `form-backend-ui` ungecommittet umgesetzt: Zinc-/Inter-
Fundament, Theme/Systemmodus/Akzent, UI-Primitiven, Sidebar/TopBar mit mobilem
Drawer sowie Login, Setup und Formularüberblick. Andere Seiten laufen in der
Shell weiter; ausgeschlossene Schlüsseldateien unverändert. ADR 0022 und
`docs/handoffs/P12-A.md` enthalten Dateibesitz, Vertrag und Fortsetzung.
Check/Lint, 81 Vitest-Tests und Build bestanden; 45 Playwright-Fälle erkannt.
Playwright/axe und visuelle Abnahme offen: Sandbox blockiert Preview-Listener
mit `EPERM ::1:4173`. Keine laufenden Jobs, Dateibesitz frei, keine Delegation,
kein Commit/Deployment. Nächster Schritt: Browserlauf außerhalb der
Listener-Sperre, visuelle Abnahme, dann Schritt 2.


## Hold-Playwright-Mock nach P12-B (03.11.2026)

Paket `fix-e2e-hold` im Worktree `form-backend-fix2` ungecommittet korrigiert. Ein Codex, keine Delegation; Dateibesitz `pwa/e2e/admin.spec.ts`, P12-B-Handoff und STATUS/ARBEITSPLAN bei Übergabe frei, keine Jobs. Ursache: fehlendes Holdinventar (404), gesperrter Keyring bei Direktnavigation und veraltete Requesterwartung ohne Objekte. Mock bietet nun regulären Login/PRF-Autounlock mit echten synthetischen Schlüsselhüllen und zustandsbehaftete Holdobjekte; prüft CAS, sym-Rewrap/Nutzbyte-Erhalt und Fehler bei gesperrtem Zugang. UI zeigt Fehler bereits an, daher unverändert. Check/Lint/89 Vitest/diff --check bestanden; Playwright auf Nutzerauftrag nicht ausgeführt (bekannte EPERM-Grenze). Details/Vertrag/Dateien: `docs/handoffs/P12-B.md`, Nachkorrektur. Nächster Schritt beim Nutzer: `cd pwa && npx playwright test`; kein Commit oder Deployment, vollständiges P12-B weiterhin offen.

## P7-F – Session-Merker und kurzer Primärtimeout (03.11.2026)

Erweiterung im Hauptcheckout `form-backend-fo2`, Branch `feature-fo2`, ungecommittet. Ein Codex ohne Delegation; Dateibesitz SDK-Client/neuer Session-Test/README, ADR 0023, P7-F-Handoff und STATUS/ARBEITSPLAN bei Übergabe frei. Keine laufenden Jobs. Vertrag/Abnahme: aktive PHP-Session als einziger Merker (60 s, nur Zeitstempel/Index), ohne Session zustandslos, optionaler Start ausschließlich vor Headerausgabe, keine Host-Session schließen/committen; signierte Liste nur umordnen. Primärversuch bei Backup standardmäßig maximal 3 s, Gesamtbudget 10 s; `connectTimeout`/`totalBudget`/`failoverTtl`/`sessionStart` dokumentiert, alte Budgetkonfiguration kompatibel. Keine neuen Extensions/Datei-Merker/Migrationen.

PHP geprüft: 120 SDK + 47 cURL + 40 neue Session-Failover-Prüfungen bestanden, alle SDK-PHP-Dateien syntaxgültig, diff --check bestanden. Virtuelle Zeit statt echter Netzwerkwartezeit; reale Host-Sessionhandler-/TLS-/Proxy-Abnahme und unabhängiges Review offen. Dateien, Testbefehle und nächster Schritt: `docs/handoffs/P7-F.md`, Erweiterungsabschnitt. Kein Commit/Push/Deployment.

## P11-F Teil 1 – Formular-Konverter (03.11.2026)

Paket auf `feature-conv` / Worktree `form-backend-conv` ungecommittet implementiert.
Ziel/Dateibesitz/Vertrag/Abnahme: ADR 0025 und `docs/handoffs/P11-F-Konverter.md`.
Ein schreibender Codex, keine Delegation; Dateibesitz bei Übergabe frei, keine laufenden Jobs.
P9-Legacyprojektion → validierter inaktiver Entwurf; separate unvollständige Mail-/Domain-
Vorschläge, wertfreier Bericht. POST/GET mit frischer Cookie-Sitzung, system.manage auf
Systemscope, POST mit CSRF/Origin; Transaktion/Audit, wiederholbar ohne Überschreiben.
Keine Aktivierung, Veröffentlichung, Mailzuordnung oder Alt-DB-/Dump-Lektüre.

Swift-Build inklusive Testkompilierung erfolgreich; fünf reine Konvertertests bestanden,
git diff --check bestanden. DB/API-Tests (Rechte, Frische, CSRF, Wiederholung/Edits,
Inaktivität, Auditrollback und synthetische 3 Formulare/28 Felder auf legacy.sql) geschrieben
und kompiliert, auf Nutzerauftrag nicht ausgeführt. Baseline-DDLs haben vorhandene OAuth-
Abweichungen; Konverterzusatz identisch. Bestandsupgrade 0025 nur ungeprüfter Kandidat,
keine produktive Migration und keine Änderung gespeicherter Schema-Prüfsummen.
Nächster Schritt: Docker-Abnahmebefehl im Handoff, unabhängiges Review, Mail-/Domain-/
Spezialhandlerprüfung vor menschlicher Veröffentlichung. Keyimport/Delta/Rollback bleiben
weitere P11-F-Teile. Kein Commit/Push/Deployment.

## Auditfix Session/Keyring und DCR (03.11.2026)

Branch `fix-audit`, Worktree `form-backend-auditfix`, ein Codex ohne Delegation.
Abgegrenzter Nutzerauftrag: Keyring an Konto/Sitzung binden und Tabs sperren;
globale DCR-Budgets und 24-h-Ablauf ungenutzter Registrierungen. Implementiert;
Vertrag/Dateien und Quellenabweichung des älteren Auditberichts im Nachtrag zu
`docs/handoffs/P11-E.md` und ADR `0022-mcp-oauth.md`. Keine Schemaänderung.
Dateibesitz Session/Keyring/Session-Vitest, OAuthRoutes/AuthMaintenance/Registry,
OAuthIntegration-/Registrytests und diese Dokumente. Prüfabschluss siehe Handoff;
DB-Tests ausdrücklich nicht ausführen (Docker fehlt). Kein Commit/Deployment.
Nächster Schritt: neue OAuth-DB-Regressionen in Docker, danach echte Zweitab-
Browserabnahme und unabhängiger Sicherheitsreview.

Auditfix-Prüfabschluss: 107 Vitest, Svelte-Check (0/0), gezieltes ESLint/Prettier,
PWA-Build, `swift build --build-tests`, 4 DB-freie SettingsRegistryTests und
`git diff --check` bestanden. DB-Tests nur kompiliert, Browserabnahme offen.
Dateibesitz frei; keine laufenden Jobs, nichts committet. Handoff P11-E enthält
Fortsetzungsbefehle und Grenzen.
## Export/Auskunft — FA-061/068/073–075 (03.11.2026)

Auf `feature-export` / Worktree `form-backend-export` ungecommittet implementiert:
lokale Volltext-/Personensuche mit UTC-Zeitraum, Auswahl als CSV/JSON nach lokaler
Entschlüsselung mit dem Keyring, Formelneutralisierung, sichtbare Fehler-Marker,
gezielte bestätigte Löschung entschlüsselter Treffer. Live-PermissionService über
vorhandene Chiffratrouten und neue lokale Zugriffsauskunft; expliziter wertfreier
Audit-Aufruf vor Download. Keine Klartextsuche auf dem Server oder Browserpersistenz.
Keine neuen Einstellungen/Schema-Teile, daher keine Upgrade-/Splitteränderung nötig.
Vertrag/Begründung: ADR 0026; vollständige Dateien/Tests/Grenzen in
`docs/handoffs/Export-Auskunft.md`. Ein Codex ohne Delegation; Dateibesitz frei,
keine laufenden Jobs, keine Commits oder Deployments.

Nachgewiesen: Swift-Build inklusive Tests (Exit 0), 28 gezielt DB-freie Swift-Tests,
Svelte check ohne Fehler/Warnungen, Lint und 118 Vitest-Tests sowie diff --check
bestanden. Neue DB-Tests nur geschrieben und kompiliert, auf Nutzerauftrag nicht
ausgeführt; Docker und Playwright nicht gestartet. Suche pro Formular, Datenexport
ohne Anhänge; kein Bestandssnapshot, große Zeiträume benötigen entsprechenden
Browserspeicher. Nächster Schritt: PrivacyTests mit Docker und echte Browser-/PRF-/
Tabellenkalkulationsabnahme sowie unabhängiger Sicherheitsreview (Befehl im Handoff).
## Betrieb — in Umsetzung (03.11.2026)

Nutzerpaket FA-085/086/089/063/134/135 auf `feature-ops`, Worktree `form-backend-ops`.
Ein schreibender Codex, keine Delegation; Dateibesitz Ops-Neudateien Backend/PWA,
minimaler Anschluss/SettingsRegistry/i18n, DDL+Upgrade 0026, Splittertest, Dokumentation.
Vertrag ADR 0026, Dateien/Abnahme/Grenzen `docs/handoffs/Betrieb.md`. API, UI,
transaktionale sichere Chronik, gedrosselte Mailalarme und autorisierte Bereinigung
implementiert; lokale Prüfungen laufen. DB-Tests nur kompilieren; Docker/Playwright
auf Nutzerauftrag nicht ausführen. Kein Commit/Deployment/produktive Migration.

Betrieb — Prüfabschluss (03.11.2026): lokal implementiert, ungecommittet.
Swift-Testbuild erfolgreich (abschließend 48,81 s), 10 DB-freie Ops-/Registry-/
Splittertests erfolgreich, PWA check/lint und 107 Vitest-Fälle erfolgreich,
diff --check und Schema-/Upgradegleichheit bestanden. Zwei DB-Tests geschrieben
und kompiliert, ausdrücklich nicht ausgeführt; keine Docker-/Playwright-/SMTP-Abnahme.
Dateibesitz frei, keine laufenden Jobs. ADR 0026 und `docs/handoffs/Betrieb.md`
enthalten API, elf Trigger, Rechte, Settings, Prüfungen und Grenzen. Nächster Schritt:
unabhängiger Review und isolierte MariaDB-/SMTP-/Upgradeabnahme durch Koordination.

Betrieb — letzte Nachprüfung: Alarmquittierung transaktional pro Ereignis statt
MAX-ID-Cursor (Commitreihenfolge), Versandziel pro Mailversuch festgehalten.
Erneuter Testbuild 15,24 s und erneut 10 DB-freie Tests erfolgreich. DB-Abnahme
bleibt offen; Handoff aktualisiert, keine Jobs, Dateibesitz frei, kein Commit.
## Paket Konten (03.11.2026)

Auf `feature-accounts` im Worktree `form-backend-accounts` lokal in Umsetzung, ungecommittet; ein Codex ohne Delegation. Vertrag/Dateibesitz: ADR 0026 und `docs/handoffs/Konten.md`. Öffentlicher TOTP-Alternativ-/Ergänzungsweg, bestätigte Einrichtung, Passwortentfernung, kontoweite 5/900-Sperre, Replay-Schutz und SecretStore-Reencrypt; Kontostatus/MCP-Freigabe live sowie zusätzlicher Token-/OAuth-Widerruf beim Passwortwechsel. Schema plus Upgrade 0026; DB-Tests nur schreiben/kompilieren, Docker/Playwright nicht ausführen. Prüfabschluss folgt im Handoff; keine produktiven Jobs/Migrationen oder Commits.

Prüfabschluss Paket Konten: vollständiger Swift-Testbuild Exit 0, 18 DB-freie Swift-Tests bestanden, PWA check/lint/105 Vitest-Tests grün, diff --check bestanden. DB-Tests inklusive Nebenläufigkeit/Auditrollback geschrieben und kompiliert, auf Nutzerauftrag nicht ausgeführt; Docker/Playwright nicht gestartet. ADR 0026, Upgrade 0026 und genaue Befehle/Grenzen in `docs/handoffs/Konten.md`. Keine laufenden Jobs, Dateibesitz frei, nichts committet. Nächster Schritt: isolierte MariaDB-/Browserabnahme und unabhängiger Sicherheitsreview; Rotation bleibt explizite interne Wartungsfunktion.
## Missbrauchsschutz – Paketstand 03.11.2026

Worktree `form-backend-abuse`, Branch `feature-abuse`, ein Codex ohne Delegation.
FA-012/013/014/016/017/033/034/044 implementiert; Vertrag/Dateibesitz, Prüfungen,
Grenzen und Fortsetzung in `docs/handoffs/Missbrauchsschutz.md`, Entscheidung ADR
0026. Kein Commit, Deployment oder produktive Migration. DB-Tests geschrieben,
auf Nutzerauftrag nicht ausgeführt; Docker/Playwright nicht gestartet. Swift-Testbuild, 46 DB-freie Swift-Tests sowie PWA-Check/Lint/105 Vitest-Fälle
bestanden. Vertragsvalidator wegen fehlendem jsonschema nicht ausgeführt;
bestehende OAuth-DDL-Abweichungen bleiben außerhalb des Pakets. Keine laufenden
Jobs, Dateibesitz frei. Nächster Schritt: separate DB-/Browserabnahme und Review;
Befehle und Grenzen im Handoff.
## P11-C/D – laufender Implementierungsstand 03.11.2026

Branch `feature-assist`, Hauptcheckout `form-backend-assist`, ein schreibender Codex,
keine Delegation, keine Commits. Ziel/Dateibesitz: Setup-/Migrationssteuerung Backend,
PWA Installation/Migration/Shell/Settings, P9-Schema-/Checkpoint-Erweiterung,
Rechtekatalog/DDL/Upgrade 0026, zugehörige Tests und Dokumentation. ADR 0026 und
`docs/handoffs/P11-CD.md` sind der Fortsetzungsvertrag. Laufende Prüfungen liegen in
`/private/tmp/p11-cd-*.log`; keine Docker-/Playwright-Läufe. Paket noch nicht abgeschlossen:
kontoweite P12-B-Recovery fehlt im Checkout; Assistent blockiert Schritt 2 korrekt.
Prüfabschluss und weitere Grenzen werden im Handoff fortgeschrieben.

P11-CD Prüfabschluss: Swift `build --build-tests` erfolgreich (abschließend 17,34 s),
2 gezielt ausgewählte DB-freie Sicherheitsfälle bestanden. PWA check ohne Fehler/
Warnungen, Lint/Prettier, 112 Vitest-Tests und Build bestanden; diff --check bestanden.
Neue DB-Tests für Rechte/CSRF/Frische, SecretStore/stabilen HMAC, Crashzustand,
Schema-Pin und Dry-run-/Commit-Abbruchgrenzen geschrieben und kompiliert, ausdrücklich
nicht ausgeführt. Playwright geschrieben, nicht ausgeführt. DDL-Erweiterungen stimmen
überein; historische OAuth-Baselineabweichungen unverändert. Keine produktive Migration.
Dateibesitz frei, keine laufenden Prüf-/Anwendungsjobs, nichts committet. Nächster Schritt:
P12-B-Kontorecovery integrieren und Assistentenschritte 3–6 samt echter Datenprobe
vervollständigen, danach unabhängige MariaDB-/Browser-/Sicherheitsabnahme. P11-C/D
bleiben als Gesamtpaket unvollständig; keine Fertigmeldung für den Setupassistenten.
## MCP-Werkzeuge – Arbeitsstand 03.11.2026

Paket FA-122/123/124 auf `feature-mcpstat` im Worktree `form-backend-mcpstat`,
ungecommittet; ein Codex ohne Delegation. Dateibesitz MCPRoutes/neue MCP-Dateien,
MCP-Tests/eigene de.ts-Schlüssel plus Paketdokumentation; OAuth/Altbackend nur gelesen.
Sechs begrenzte Werkzeuge vorbereitet, Rechte über PermissionService, explizites Formular,
Ads nicht verfügbar; Status deckt akzeptierte Einsendungen ab. RFC-8414-Metadaten und
Registry-Tokenlimit sind bereits vorhanden. Keine Schemaänderung erforderlich.
**Noch nicht abgeschlossen:** Freigabe für TokenService.swift (eigener Scope statt
stiller Erweiterung vorhandener Tokens) und StatisticsRoutes.swift (gemeinsamer Reader)
beim Nutzer angefragt; bis Antwort diese Dateien nicht verändern. ADR 0026 und
`docs/handoffs/MCP-Werkzeuge.md` enthalten Vertrag/Tests/Fortsetzung.
Prüfungen laufen; TypeScript/Svelte-Check bereits ohne Fehler. DB/Playwright nicht ausführen.

## P13-Ads – Übergabe (03.11.2026)

Auf `feature-ads` / Worktree `form-backend-ads`, ungecommittet. Ein Codex ohne
Delegation; Dateibesitz frei, keine laufenden Jobs. Vertrag/Dateien/Altcodebelege:
ADR 0032 und `docs/handoffs/P13-Ads.md`. Präsenzindikator am Besuch/signierten
Submit, nullable Bestand, gemeinsames geschütztes Aggregat für REST/MCP,
PWA-Statistikansicht. `ads_statistics` ersetzt den Platzhalter; `statistik_ads`
bleibt Aufrufalias. Kampagnen im geprüften Altcode nicht ausgewertet; Ausgabe
kennzeichnet dies ausdrücklich. Keine Roh-GCLID/IP/UA oder neue Klickverknüpfung.
Upgrade-Kandidat 0031, Frist 13 Monate und StatisticsEraser unverändert wirksam.
Swift-Testbuild/10 DB-freie Tests, PWA Check/Lint/136 Vitest und diff --check
bestanden. DB-Tests geschrieben/kompiliert, nicht ausgeführt. Keine Migration,
kein Commit/Deployment. Nächster Schritt: unabhängiger Review, isolierte DB-/
Browserabnahme und Hostansichts-Instrumentierung laut Handoff.
## Sicherheitskorrekturen Audit — 03.11.2026

Paket Todolino `8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D` auf `audit-run` /
`form-backend-audit`, Basis `298b6c0`, ohne Commit. Konverterregistrierung nur intern,
Migration mit strikter Netzfreigabe einschließlich öffentlicher IPs und unverändertem
DNS-Pinning; SMTP/Webhooks unverändert. TOTP-Benutzername vor Lookup/Throttle getrimmt.
Passwortwechsel-Race als offener Befund in ADR 0027 dokumentiert.
Ziel, Dateibesitz, Testumfang und Fortsetzung: `docs/handoffs/Audit-8B72B9D6.md`.
Swift-Testbuild mit nativem Builder erfolgreich; sechs DB-freie Tests und Diffprüfung
bestanden. DB-Tests nur kompiliert, DB-Abnahme beim Nutzer, kein Dockerlauf.
Dateibesitz frei, keine laufenden Jobs. Nächster Schritt: MariaDB-Abnahme/Review laut Handoff.

## Deploy-Vorlagen – Audit 8B72B9D6 (03.11.2026)

Paket Todolino `8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D` auf `fix-deploy` /
`form-backend-deploy2`, Basis `640b057`, ungecommittet. Ein Codex ohne Delegation.
Dateien/Vertrag/Abnahme/Umstieg: `docs/handoffs/Deploy-8B72B9D6.md`, ADR 0020/0021/0030.
Deploy-Inventare und Compose/Swarm an aktuelle SettingsRegistry angepasst; optionales
ENV-Passthrough erhält DB-Einstellungen und Legacy-Proxy-Fallback. Port-Datei-Overrides
werden abgewiesen, bevor Listener und Veröffentlichungsziele auseinanderlaufen können.
Zwei nginx-Hostbeispiele samt korrekten Proxy-CIDRs/Rate-Limit-Folgen dokumentiert.
`python3 scripts/check-deploy.py` bestanden: echte Docker-CLI-Syntaxprüfung ohne Daemon
für Compose/Swarm, Port-/Proxy-/Registry-/Persistenzregressionen und Secret-Ausschluss;
Orchestrierung mit Kommando-Doubles. Shellsyntax und `git diff --check` bestanden.
Keine Laufzeit-/TLS-/nginx-/DB-Abnahme, kein Deployment/Migrationslauf/Commit.
Dateibesitz frei, keine laufenden Jobs; nächster Schritt: Review und isolierte
Proxy-/Listener-Abnahme mit zwei synthetischen Client-IPs gemäß Handoff.
## P11-F Rest — lokale Probe und Snapshot-Delta (03.11.2026)

Todolino 8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D auf `feature-keyimport` /
`form-backend-keyimp` ungecommittet implementiert. Vertrag ADR 0033; vollständige
Dateien, Prüfungen, Grenzen und Fortsetzung: `docs/handoffs/P11-F-Rest.md`.
Browser entschlüsselt Ledgerprobe lokal, bestätigt ausschließlich Chiffrathash,
erzeugt/prüft danach lokale HPKE-Testnachricht. Server erhält keine Klartexte oder
privaten Datenschlüssel. Delta mit neuem Snapshot geht erneut durch Prüflauf;
bestehende Quell-IDs behalten ihre ursprünglichen HMAC-/Zielnachweise. Bestehende
Pause/Quellentfernung/Settings-Deaktivierung wiederverwendet, Rollbackhinweis ergänzt.
Upgrade 0032 ergänzt nur zwei nullable Hashspalten, nicht produktiv ausgeführt.
Swift-Testbuild und PWA Check/Lint/159 Vitest erfolgreich; DB-Tests ausschließlich
kompiliert. :2/hpke/X25519-Grenze, kein Löschabgleich/Cutover/RSA-Konverter.
Ein Codex ohne Delegation/Commits; Dateibesitz bei Übergabe frei, keine laufenden
Anwendungsjobs. Nächster Schritt: unabhängiges Review und DB-/Browserabnahme
beim Nutzer gemäß Handoff; externer Todolino-Status unverändert.

- Ingest-Validierung (FA-024, ADR 0034) und Entfernen der Transportfelder: umgesetzt, Suite 419 grün. Codex-Limit bis 10.11.2026.

- Abgeleitete Mailwerte (join/firstNonEmpty/date/now, ADR 0035) ersetzen die Spezialhandler der drei Altformulare; PWA-Editor dafür fehlt noch.

- Restore-Probe (03.11.2026) gegen die migrierte Test-DB: backup-db.sh/restore-db.sh liefen erfolgreich, 76 Tabellen, Zeilenzahlen gleich. Dabei zwei Skriptfehler behoben (mariadb-dump kennt --connect-timeout nicht; docker -i verschluckte die Tabellenliste in db_counts).

- **Offener CI-Befund (04.11.2026):** Backend-Job (Linux amd64/arm64) hängt auf GitHub-Runnern in mehreren Läufen bis zum Timeout (zuletzt in `OAuthIntegrationTests.testGlobalRegistrationBudgetAndUnusedCapAreAtomic`, davor nach den Mail-Tests); lokal im gleichen Container (auch mit 2 CPUs) laufen alle 422 Tests in ~90 s grün. `backend/ci-linux.sh` bricht jetzt nach 45 min mit „HANG“ ab. Verdacht: Verbindungspool/Nebenläufigkeit bei gleichzeitigen `app.test`-Aufrufen unter Last; nicht belegt.

- PWA: Webhook-Verwaltung (Liste, anlegen mit einmaliger Schlüsselanzeige, pausieren, löschen) und Editor für abgeleitete Mailwerte (ADR 0035) im Mail-Tab; Roundtrip-Test verhindert Datenverlust von `form.mail.derived`. Vitest 164, Playwright 74.

- **Proxy-Probe (06.11.2026, `backend/proxy-probe.sh`):** Release-Image + MariaDB + nginx mit öffentlichem/internem Host: Listener-Trennung bestanden (intern: Admin-API/PWA, öffentlich: Submit/MCP/OAuth; Admin-API, PWA und Setup öffentlich 404). Dabei echten Fehler gefunden und behoben: das Image enthielt `db/upgrades/` nicht, `migrate` brach bei Neuinstallation mit „schema file not readable“ ab (Dockerfile kopiert jetzt `db/upgrades`).

- **Echt-E2E (06.11.2026, `backend/e2e-setup.sh`):** vollständiger Pfad gegen die echte Binary: Setup-Link → Passkey (PRF) → Wiederherstellungscode → Setup-Assistent → Kunde → Formular → Felder → Veröffentlichen → Einrichtungsdatei → echte PHP-SDK-Einsendung über den öffentlichen Listener → Entschlüsselung im Browser → Replay idempotent → unbekanntes Feld wird abgelehnt (422) → Abmelden. Dabei zwei Fehler behoben: Login-Seite zeigte nach dem Abmelden einen veralteten „angemeldet“-Zustand (Race in `enter()`/`logout()`), und die Skripte brachen bei Aufruf über den Alias-Pfad `Documents/…` mit Swift-Modulcache-Fehlern ab (`pwd -P`). `real-admin` ist ersetzt (Formulare anlegen erfordert die Schlüsseleinrichtung).

- **Migrations-Echtlauf (06.11.2026, `backend/e2e-migration.sh`, Dump über `LEGACY_DUMP`, nie im Repo):** neue Instanz + Alt-DB mit lesendem Benutzer → Umstieg-Oberfläche → Quellprüfung → Vorbefüllung → Prüflauf: 3 Formulare, 28 Felder importiert, 10 Einsendungen als Prüfbedarf, Mail-Verbindungen zugeordnet; `cutoverReady` bleibt false. Dabei Fehler behoben: Svelte wertete `{64}`/`{6}` in `pattern`-Attributen als Ausdruck (SHA-256-Felder der Migration und das TOTP-Feld waren dadurch unbrauchbar).

- **Lastprobe (06.11.2026, `backend/loadtest.sh`, Details `docs/handoffs/Lastprobe.md`):** Wegwerf-DB + echte Binary, Formular über die Oberfläche, PHP-SDK mit 8 Workern: 400 eindeutige Keys + 50 Wiederholungen + 8-fach-Race auf einen Key, 458 Anfragen alle 200, kein 429/5xx, p50 81 ms, p95 94 ms (Debug-Build, Loopback, M4 Pro), 401 gespeicherte Einsendungen = eindeutige Keys, keine Duplikate, `/ready` 200 danach. Rate-Limit-Verhalten und Release-/Proxy-Last nicht gemessen.
- **MCP-Echtlauf (06.11.2026, `backend/e2e-mcp.sh`):** persoenliches Token und OAuth (DCR, PKCE, Consent, Refresh-Replay) gegen die echte Binary am oeffentlichen Listener, Fremdkunden-Isolation, 401. Zwei UI-Fehler behoben (Token-Liste hielt aktive Tokens fuer widerrufen; Consent-Seite wurde bei offenem Setup umgeleitet). Details: `docs/handoffs/E2E-MCP.md`.

- **SDK-Failover-Echtlauf (06.11.2026, `backend/e2e-failover.sh`, Details `docs/handoffs/E2E-Failover.md`):** zwei Instanzen auf einer DB als Primär/Backup, PHP-SDK mit Datei-Session: Primär bedient; geschlossener Primär-Port -> Backup mit Merker; stummer Primär kostet einmal ~3 s, Folgeaufruf in TTL 41 ms direkt Backup; nach TTL wieder Primär zuerst; unsignierte/manipulierte Liste abgelehnt. Kein Produktfehler. Nicht im Echtlauf: Ausstellung der signierten Liste über die Admin-API (braucht HTTPS-Hosts) und echte TLS/Proxy-Zeiten.

- **CI (06.11.2026):** Job `e2e-real` (Smoke, Login, Setup, MCP/OAuth gegen echte Binary + MariaDB + Chromium) läuft auf Linux grün und ist blockierend; Toolchain wird aus `swift:6.3-noble` kopiert (setup-swift kennt 6.3 nicht). SDK-Failover im Echtlauf (`backend/e2e-failover.sh`) und Lastprobe (`backend/loadtest.sh`, 458 Anfragen, p95 94 ms) lokal bestanden, nicht in der CI.

- Entscheidungen 06.11.2026 (Nutzer): Opus-Zweitreview vorerst nicht (später offen); Ingest-Rate-Limit-Standard 60/min bleibt; Aktivschalter nutzt `release.publish`.

- **Abhängigkeiten (06.11.2026, Dependabot-PRs abgearbeitet):** Patch/Minor der PWA, ESLint 10, swift-nio-ssh 0.15.1, Swift-Basisimage 6.4 (Linux-Suite 426 Tests, SFTP-Echttest, Proxy-Probe grün), GitHub-Actions-Majors (ungetestet, Actions laufen im privaten Account nicht). **Abgelehnt:** TypeScript 7 (svelte-check verlangt TS 6 + Experimental-Flag, typescript-eslint <6.1).

> **Hinweis zum öffentlichen Export:** Verweise auf `docs/paritaet/` (Analyse des Altsystems), `docs/handoffs/` (interne Übergaben) und `.claude/agents/` zeigen auf Material, das in dieser Veröffentlichung bewusst fehlt. Maßgeblich sind README, `docs/BETRIEB.md`, `docs/decisions/` (ADR) und `contracts/`.
