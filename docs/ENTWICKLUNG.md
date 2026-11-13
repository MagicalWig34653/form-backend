# Effiziente Entwicklung mit Claude Code und Agents

## Bestätigter Rahmen

Claude Code koordiniert. Agents mit Sonnet und Haiku nach Schwierigkeit; Codex dort einsetzen, wo sinnvoll. Ziel: geringer Tokenverbrauch bei wenigen Fehlern, nicht maximale Agentanzahl. Konkrete Modellversionen nicht in Dokumentation festnageln. Die Agentdefinitionen verwenden Sonnet-/Haiku-Aliase.

## Rollen

| Rolle           | Modell/Werkzeug                                   | Typische Pakete                                                                                      |
| --------------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Koordination    | Claude Code; Hauptmodell nach Nutzerkonfiguration | Zerlegen, Verträge abstimmen, Kontext auswählen, Integration und Abnahme                             |
| Architektur     | Sonnet                                            | Sicherheitsprofile, Ablaufsemantik, Verträge, Datenmodell                                            |
| Implementierung | Sonnet oder Codex                                 | abgegrenzte Backend-/PWA-/SDK-Aufgaben, Fehleranalyse, Adapter                                       |
| Routine         | Haiku                                             | klar beschriebene Dokumentpflege, einfache Zuordnungen, repetitive Anpassungen nach bewährtem Muster |
| Review          | Sonnet oder Codex unabhängig vom Autor            | Rechte, Nebenläufigkeit, Kryptokompatibilität, Migration, Fehlerpfade                                |

Haiku bekommt keine eigenständigen Sicherheits-, Migrations- oder Architekturentscheidungen. Bei Unklarheit stoppt die abhängige Änderung und die Rolle eskaliert an die Koordination. Sonnet muss ebenfalls keine unklaren Produktentscheidungen erraten.

Codex ist keine vorausgesetzte installierte Integration. Vor Delegation prüfen, welches CLI/Plugin verfügbar und autorisiert ist. Sonst Paket ohne fingierte Delegation in Claude Code bearbeiten oder Verfügbarkeit offen melden. Keine feste Codex-Quote, keine erfundenen Toolbefehle.

## Nutzervorgabe Codex-Anteil (26.10.2026)

Der Nutzer hat festgelegt: Rund 75 % der delegierbaren Pakete gehen an Codex mit Modell `gpt-6.1-sol`. Ist Codex wegen Limit oder Fehler nicht nutzbar, übernimmt Claude (Sonnet/Haiku) als Fallback; der Fallback wird im Handoff vermerkt. Das ersetzt für diese Quote die Aussage „keine feste Codex-Quote". Prüfstand 26.10.2026: `codex-cli 0.164.0`, ChatGPT-Login aktiv; Verfügbarkeit von `gpt-6.1-sol` ist noch nicht bestätigt.

## Ablauf eines Pakets

1. Koordination liest STATUS/ARBEITSPLAN und nur relevante Verträge.
2. Gemeinsame API-, Ereignis-, Schema- oder Migrationsänderungen zuerst festlegen.
3. Paket mit Ziel, Nicht-Zielen, Dateien, Kontext, Abnahme und Tests beschreiben.
4. Exklusiven Dateibesitz vergeben; bei umfangreicher paralleler Arbeit getrennte Worktrees/Branches verwenden. In gemeinsamem Checkout niemals gleichzeitig dieselben Dateien schreiben.
5. Agent liest gezielt und implementiert nur den Auftrag. Keine ungebremste rekursive Delegation.
6. Agent führt passende Prüfungen aus und liefert kompakte Übergabe mit Belegen.
7. Risikobasiertes unabhängiges Review. Koordination integriert, prüft Vertragskonsistenz und führt relevante Integrationstests aus.
8. STATUS, ARBEITSPLAN und gegebenenfalls ADR/Vertrag mit dem Ergebnis aktualisieren.

## Paketvertrag

- ID, Ziel und fachlicher Nutzen.
- Verbindlicher Eingabe-/Ausgabevertrag und referenzierte Anforderungen.
- Erlaubte Dateien/Verzeichnisse und ausdrücklich ausgeschlossene Änderungen.
- Abhängigkeiten, bestehende Beispiele und benötigte Entscheidungen.
- Abnahmefälle einschließlich relevanter Fehler-/Retry-/Rechtefälle.
- Zu verwendende Testbefehle, sofern tatsächlich eingerichtet.
- Erwartete Übergabe: Ergebnis, Dateien, Prüfungen, Grenzen, Integration.

Ein Paket soll eine überprüfbare fachliche Änderung ergeben. Keine riesigen Pakete wie „Backend bauen“ und keine Aufteilung in zahlreiche trivial kleine Agents mit mehr Kontextkosten als Nutzen.

## Token und Fehler reduzieren

- Kurze gezielte Suchergebnisse statt vollständiger Repository-Dumps.
- Zentraler Vertrag und Entscheidungsindex; Details nicht in jedem Dokument duplizieren.
- Agents erhalten ein kurzes Kontextpaket mit Pfaden und wenigen relevanten Abschnitten, nicht die ganze Unterhaltung.
- Unabhängige Backend-/PWA-Arbeit erst nach stabilem Vertrag parallelisieren.
- Strukturierte, kurze Übergaben statt Rohlogs. Bei Fehlern nur relevante Auszüge.
- Tests nach Risiko: Unit für Regeln, Integration für MariaDB/Transaktionen, Browser für kritische UI-Flows, PHP/Swift/Browser-Kreuztests für Protokoll/Krypto.
- Geänderte Bereiche prüfen; breite Gesamtsuite an Integrationspunkten statt blind nach jedem kleinen Schritt.
- Ein hochwertiges unabhängiges Review für Hochrisikopfade statt vieler gleichartiger Rundumreviews.
- Aufwand erst nach realen Paketen bewerten: Nacharbeit, Fehlerrate und Kontextkosten; keine erfundenen Tokenbudgets oder Sparversprechen.

## Definition of Done

Anforderung erfüllt, Vertrag und Dokumentation konsistent, passende Prüfungen erfolgreich oder klar als offen ausgewiesen, keine Secrets/Kundendaten, Fehler-/Rechtepfade berücksichtigt, Review nach Risiko, integrierbarer Stand und kurze Übergabe. Bestehende Funktionen bleiben durch eine fortgeschriebene Paritätsmatrix nachweisbar.

Bei Änderungen, die in das Image eingehen (Backend, PWA, Dockerfile, Entrypoint, SDK): **Image bauen, Smoke-Test, Tag in `post_progress`.** Also `scripts/docker-build.sh` ausführen und die Zeile `IMAGE_TAG=form-backend:<hash>` mit dem Smoke-Ergebnis im Fortschritt der Aufgabe nennen.

## E2E-Skripte: eindeutige Namen (Regel)

Jedes `backend/e2e-*.sh`, `smoke-admin.sh`, `loadtest.sh`, `proxy-probe.sh` bindet `backend/e2e-common.sh` ein und nutzt **keine festen Container-/Netznamen**: Namen per `e2e_name <basis>` (`<basis>-<RUN_ID>`), Docker-Objekte mit `"${E2E_LABEL_ARGS[@]}"` (Label `e2e.run=<RUN_ID>`, `e2e.started=<epoch>`), Aufräumen nur per `e2e_cleanup` (Label), nie per Namensmuster oder `docker rm -f NAME` vor dem Start. `e2e_reap_stale` entfernt verwaiste Objekte fremder, toter Läufe nur über das Label und nur bei Alter > 6 h (`E2E_STALE_HOURS`). Ports bleiben per `P3B_PORT`/`E2E_PORT`/`LEGACY_PORT` usw. setzbar (CI tut das), ohne Angabe wählt `e2e_pick_port` einen freien 128er-Block (20480-32639, per Sperrverzeichnis reserviert). Die PWA wird je Lauf nach `$TMP/dist` gebaut, Playwright schreibt nach `$E2E_OUTPUT_DIR`, nicht in die gemeinsamen `pwa/dist`/`pwa/test-results`. Prüfung: `scripts/check-e2e-rc.sh` (Muster), `scripts/test-e2e-parallel.sh` (zwei Läufe gleichzeitig). Gleichzeitige Läufe teilen weiter `backend/.build` (SwiftPM serialisiert per Sperre).

## Lokales Image (Build und Smoke-Test)

```
scripts/docker-build.sh              # PWA bauen (falls nötig), Image bauen, Smoke-Test, aufräumen
scripts/docker-build.sh --no-smoke   # nur bauen
scripts/docker-build.sh --keep       # Smoke-Container/-Netz zum Untersuchen behalten
scripts/docker-build.sh --smoke-image form-backend:<hash>   # nur Smoke-Test eines vorhandenen Images
scripts/test-docker-build.sh         # Selbsttest der Aufräumlogik und des Fehlerverhaltens (Dummy-Images, kein Voll-Build)
```

- Baut für die native Architektur aus dem aktuellen Checkout (`backend/Dockerfile`, Kontext Repo-Wurzel). `pwa/dist` wird mit `npm ci`/`npm run build` erzeugt, wenn es fehlt oder älter als die Quellen ist.
- Tags: `form-backend:<12-stelliger Commit>` (bei ungesichertem Arbeitsbaum `…-dirty`) und `form-backend:latest`. Die letzte Zeile `IMAGE_TAG=…` gehört in `post_progress`.
- Smoke-Test gegen echte MariaDB in einem privaten Docker-Netz (Zufallspasswort und -Schlüssel nur in einer 0600-Env-Datei): `migrate`, `serve`, `/healthz`, `/ready`, PWA-Index mit CSP, Kernpfad (Passkey-Login mit echter WebAuthn-Assertion, Kunde, Kundenschlüssel, Formular, Release, SDK-Zugang, signierte Einsendung über die öffentliche Ingest-Route, DB-Prüfung: Zeilen in `submissions`/`stored_objects`, kein Klartext in der DB, Idempotenz). Treiber: `scripts/docker-smoke-flow.py` (Python-Standardbibliothek + `openssl`); Voraussetzungen am Host: Docker, `curl`, `python3`, `openssl`, `php` mit sodium, bei Bedarf `npm`.
- Nicht abgedeckt: die browserseitige Schlüsseleinrichtung (Kontoschlüssel per Passkey-PRF, Wiederherstellungscode, Zugriffsberechtigung auf den Datenschlüssel), Entschlüsseln im Browser, Mailversand, nginx/TLS (dafür `backend/proxy-probe.sh` in der CI). Das Konto und der Passkey werden synthetisch per SQL angelegt.
- Aufräumen: Container und Netz immer (`trap EXIT`, auch bei Fehlern); alte `form-backend:<hash>`-Tags bis auf die neuesten 3 und `:latest`; dangling Schichten nur mit dem Build-Label dieses Skripts. Kein globales `docker prune`.
- **Kein Push in eine Registry, kein Deploy.** Veröffentlichen übernimmt allein die CI auf `main`.

## Wissensablage

Anforderungen in ANFORDERUNGEN; technische Struktur in ARCHITEKTUR; Entscheidungen in decisions; tatsächlicher Stand in STATUS; aktive Pakete in ARBEITSPLAN; abgeschlossene Ergebnisse in handoffs. Keine Voraussetzung an Chatgedächtnis. Desktop-Erstkopie nicht parallel unabhängig weiterpflegen.

## Wegwerfbare Sessions — verbindliche Anforderung

Das Repository ist die alleinige Source of Truth und das dauerhafte Projektgedächtnis. Jede Claude-Code-, Sonnet-, Haiku- oder Codex-Session muss jederzeit durch eine neue Session ohne Kenntnis früherer Chats fortgesetzt werden können.

Alle zur Fortsetzung benötigten Anforderungen, Nutzerentscheidungen, Architekturbegründungen, Verträge, Arbeitsstände, Änderungen, Testergebnisse, offenen Fehler, Blockaden und nächsten Schritte müssen im Repository dokumentiert sein. Chatverläufe, Agent-Memory, lokale Notizen und Desktop-Kopien dürfen keine alleinigen Wissensquellen sein. Vollständige Chats müssen dafür nicht kopiert werden; maßgeblich sind knappe, sachliche und nachvollziehbare Ergebnisse.

Dokumentation wird im selben Arbeitsschritt wie die fachliche Änderung aktualisiert. Vor jeder Übergabe, Unterbrechung, Sessionbeendigung oder einem Kontextwechsel sind STATUS, ARBEITSPLAN und bei Bedarf Entscheidungen/Übergaben auf den tatsächlichen Stand zu bringen. Bei unerwartetem Abbruch muss sich der Stand aus kleinen nachvollziehbaren Änderungen und den zuletzt gesicherten Notizen rekonstruieren lassen.

Zu sichern sind insbesondere Paket/Dateizuständigkeiten, Branch/Worktree, laufende Jobs oder Prozesse samt Fortsetzungs-/Abbruchhinweisen, ausgeführte und fehlende Prüfungen, Migrationsfolgen und der nächste konkrete Schritt. Secrets, private Schlüssel, Zugangsdaten und echte Kundendaten werden dabei niemals ins Repository geschrieben; nur sichere Referenzen auf deren vorgesehene Ablage dokumentieren.

Abnahmekriterium: Eine neue Session kann anhand von AGENTS.md, STATUS, ARBEITSPLAN und den referenzierten Verträgen/Entscheidungen den nächsten Schritt bestimmen, ohne nach einem alten Chat fragen zu müssen.
