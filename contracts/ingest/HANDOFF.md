# Übergabe P2 – ingest

SPDX-License-Identifier: AGPL-3.0-only.


## Technische Reviewkorrekturen 27.10.2026

Status: **VORGESCHLAGEN als Vertragsentwurf**, keine Produktimplementierung oder
neue Nutzerentscheidung. Enger Auftrag ausschließlich unter `contracts/`.

### Änderungen

- H01: OpenAPI-Ressourcen-IDs auf gemeinsamen UUID-Typ referenziert; Importauflösung im README verlinkt.
- M02 (nur Technik): Signatur → technische Prüfung → Abtrennung der vier belegten Technikfelder → fachliche Normalisierung/Persistenz; keine Technikwerte persistieren.
- M03: Scope-/Release-/Modusbindung und Tombstones mit Datenvertrag abgestimmt.
- Dateien: `ingest.openapi.yaml`, `README.md`, dieses neue `HANDOFF.md`.

### Prüfungen

Beide vorhandenen Validatoren ausgeführt: Exitcode jeweils 0. Vollständige,
unveränderte Ausgaben und Prüfgrenzen: [VALIDIERUNG.md](../data/VALIDIERUNG.md).
Flow: 12 Schemas, 21 Beispiele, 46 erwartete Negativfälle. Auth: 66 Operationen,
1132 Referenzvorkommen, 11 lokale Dokumente, 37 Payloadfälle. Keine DB-/Krypto-/
Autorisierungs-/Mehrreplika-/Sandbox-Laufzeitprüfung, kein Produktionsreifeurteil.
Ältere Prüfzahlen/Offenlisten oben beschreiben den vorherigen Stand; dieser
Nachtrag ist der aktuelle Fortsetzungsstand.

### Offen und nächste Abnahme

- **OFFEN, nicht entschieden:** H02, H04, H05, H07, H09, H11, M04, M05 und alle Nutzerentscheidungen.
- **M02 nur teilweise:** technische Reihenfolge/Feldausschluss korrigiert; Legacytypen, Leerwerte, Spezialhandler/418/424, Scanner-/Mehrdateipolitik bleiben OFFEN.
- **M07 nur teilweise:** Regex korrigiert; Runtime-/Schemaquoten, IPC/Capabilities und unabhängige Sandboxabnahme bleiben OFFEN.
- Fristen/Retention, feine Rollen-/Aktionsrechte, Kunden-/Altschlüsselschnitt und MFA-/Secretprovider bleiben OFFEN; vorgeschlagene technische Details sind keine Beschlüsse.
- Gemeinsame Anschlussverträge: [abbildung.md](../data/abbildung.md) und [objektinventar.md](../data/objektinventar.md). Nächster Schritt: unabhängiger Vertragsabgleich und gesondert autorisierte synthetische P3-DB-/Replay-/Krypto-/TTL-Prüfungen, zuvor erforderliche Nutzerentscheidungen einholen.

Dateibesitz: ein schreibender Codex-Agent für die fünf beauftragten Vertragspakete,
keine Delegation. Gemeinsamer Checkout auf `main`, kein Branch-/Worktreewechsel,
keine Git-Metadatenänderung, kein Commit, keine laufenden Jobs. Altprojekt nur
für die zwei benannten technischen Feldstellen gelesen; keine Secrets oder
Kundendaten geöffnet/übernommen. STATUS/ARBEITSPLAN bleiben wegen expliziter
Schreibgrenze unverändert; Koordination muss diese Handoffs dort verlinken.


## Vertragsrunde 2 — Nutzerentscheidungen ADR 0004, 27.10.2026

Aktueller Fortsetzungsstand: Dieser Nachtrag ersetzt die früheren Offenlisten
zu H02/H04/H05/H07/H09/H11/M04/M05. **Produktentscheidungen BESCHLOSSEN gemäß
ADR 0004; neue technische Details VORGESCHLAGEN**, keine Produktimplementierung.

### Änderungsliste

- H04: Ansichtshost versus gemeinsame API-Hosts und signierte Formularauflösung angeschlossen.
- H05: TransportEnvelope/TransportPayload, zwei separate Transportendpunkte und verpflichtende Hüllensignatur in OpenAPI; reguläre PHP-Kanonisierung bleibt erhalten.
- H11: neuer legacy-adapter.md mit Docker-Vertrauensgrenze, formularbezogenen Keys, vorgeschlagener Laufzeit und Abschaltung; kein Kern-Altdecoder.
- M02: gespeicherte Legacyvalidierung versus neue typisierte Formulare, Altverhalten bei Scannerfehlern und 418/424 ausdrücklich erhalten/OFFEN.
- Dateien: README.md, ingest.openapi.yaml, neu legacy-adapter.md, dieses HANDOFF.md. Ingest-Prüfung nun zusätzlich über ../auth/validate.py.

### Tatsächliche Prüfungen

`python3 contracts/flow/validate.py`: Exitcode **0**, 12 Schemas, 21 Manifest-
beispiele, 51 erwartete Negativfälle; zusätzlicher positiver Crashzustand.
`python3 contracts/auth/validate.py`: Exitcode **0**, 76 Operationen,
1863 Referenzvorkommen, 12 lokale Dokumente, 66 gezielte Payloadfälle.
Exakte vollständige Ausgaben und zusätzliche statische DDL-Prüfung:
[VALIDIERUNG.md](../data/VALIDIERUNG.md), Abschnitt Vertragsrunde 2.
Keine DB-/Krypto-/Autorisierungs-/Docker-/HTTP-/Migrationsintegration ausgeführt;
kein vollständiger OpenAPI-Spezifikationsvalidator, keine Produktionsreife.

### Teilweise / OFFEN / nächste Abnahme

- H02/H04 als Vertrag eingearbeitet; Rechtewiderruf/Gruppenänderung über zwei
  Replikas, Bereichs-/Selbstprivilegierungsprüfung und Hostkonflikte echt testen.
- H05/H07/H09/H11 technisch spezifiziert, unabhängiges Krypto-/Vertragsreview
  und synthetische Kreuz-/Crash-/Replay-/Originalbindungsprüfungen fehlen.
  Sicherer Transportkey-Provider/Provisionierung OFFEN; Adapterlaufzeit
  90 Tage nur VORGESCHLAGEN, keine automatisch bestätigte Frist.
- M02: Legacyadaptersemantik festgelegt, vollständige Handler-/PHP-Typfixtures
  und Implementierung fehlen. Scannerentscheidung und Ersatz für 418/424
  bleiben OFFEN; bis Nutzerentscheidung gilt ausdrücklich Altverhalten.
- M04: vollständiger Nicht-IP-Altstatistikerhalt beschlossen; tatsächlicher
  IP-Bezug muss vor Import geprüft werden, nicht übernehmen, als OFFEN melden.
  Geschütztes Metadatenformat/Ads-Zugriff bleibt technischer Prüfauftrag.
- M05: Übernahme beschlossen, Hash-/Geheimnis-/PKCE-Formatprüfung und echte
  Token-/Grant-/Refreshkontinuitätsabnahme OFFEN; kein Neufreigabe-Zwang.
- Zahlenwerte/Fristen aus Nr. 21, Kunden-/Altschlüsselschnitt und nicht
  migrierbare Zeilen aus Nr. 28 sowie M07-Sandboxabnahme weiterhin OFFEN.
  Bearbeiten-DTO bleibt OFFEN; kein stilles Editieren über Resend.

Ein schreibender Codex-Agent besitzt für dieses abgeschlossene Paket
contracts/{ingest,crypto,data,flow,auth}; keine Delegation/weiteren
Dateireservierungen. Gemeinsamer Checkout auf main, kein Branch-/Worktreewechsel,
keine Git-Metadatenänderung, kein Commit, keine laufenden Jobs.
Altprojekt, secrets/ und keys/secrets.ini in dieser Runde nicht geöffnet;
keine realen Schlüssel/Kundendaten. Ausschließlich unter contracts/ geschrieben.
STATUS/ARBEITSPLAN bleiben wegen expliziter Schreibgrenze unverändert;
Koordination soll diese Handoffs dort verlinken. Nächster Schritt: unabhängiges
Review dieser Verträge, anschließend gesonderte synthetische Integrationsabnahme.


## Vertragsrunde 3 — Anschlussbefunde R01–R08, 28.10.2026

Status: **VORGESCHLAGEN**, keine Produktentscheidung getroffen. Ein schreibender Agent,
gemeinsamer Checkout `main`, kein Commit, keine Jobs.

### Änderungsliste

- R06 behoben: einheitliche Digestabbildung Transport→PHP-Struktur (`README.md`, Abschnitt R06), `TransportPayload`-Beschreibung, Kreuzvektorliste.
- R03 teilweise: Adapterwire (`X-Kubus-Adapter-*`, `KUBUS-ADAPTER-SIGN-1`, mTLS-Pin, Prüfreihenfolge) in `legacy-adapter.md`; Entscheidung D2 offen.
- R05 (Ingest-Anteil): `configuration.transportPolicy/transportKeyVersion` in `ingest.openapi.yaml`.
- M02 teilweise: `legacy-validation-v1.md`, `legacy-validation.schema.json`, `legacy-validation-fixtures.json` (17 Fälle, 3 mit `php-reference-required`); Scanner/418/424 und PCRE-Dialekt offen.
- M03 teilweise: Replay-Antworten bei gelöschten/ungeprüfbaren Treffern als VORGESCHLAGENER Rahmen in `../data/abbildung.md`; Fristen/öffentliche Antwort OFFEN (D5).

### Tatsächliche Prüfungen

`python3 contracts/flow/validate.py` (venv-Python mit jsonschema/pyyaml): Exitcode **0**,
12 Draft-2020-12-Schemas, 21 Beispiele, 53 Negativfälle (zusätzlich drei positive
`security.transport`-Varianten). `python3 contracts/auth/validate.py`: Exitcode **0**,
83 Operationen, 1988 Referenzvorkommen, 12 lokale Dokumente, 93 gezielte Payloadfälle.
Zusätzlich im Auth-Prüfer: Manifest-Schema und Beispiel mit fünf Negativfällen,
Schema/Fixtures der Legacy-Validierung, statische DDL-Textprüfungen. Nicht ausgeführt:
SQL/MariaDB, Krypto, PHP, HTTP, Mehrreplika, Sandbox; kein vollständiger
OpenAPI-Validator. Details: [VALIDIERUNG.md](../data/VALIDIERUNG.md), Abschnitt Vertragsrunde 3.
Übergreifende Entscheidungsliste: [vertragsrunde-3-offen.md](../../docs/handoffs/vertragsrunde-3-offen.md).

### Offen / nächste Abnahme

D2, D3, D5, D6 (siehe Entscheidungsliste). Pflicht: PHP-Referenzläufe für die drei
`php-reference-required`-Fixtures, Kreuzvektoren Regulär↔Transport, SDK-Matrix für `required`.

## ADR 0005 Einarbeitung (29.10.2026)

- D6 (BESCHLOSSEN): Scannerfehler lässt durch (nie 503, Status `nicht_geprueft`), 418/424 des Bewerbungshandlers bleiben; festgehalten in `legacy-validation-v1.md`, `legacy-adapter.md`, `README.md`, `ingest.openapi.yaml` (Beschreibungen). Verschärfung unbeschlossen. Fixtures je Handler/Fehlerpriorität weiterhin Prüfkriterium.
- D1 (VORGESCHLAGEN): README-Verweis auf Release-Bindung der API-/Ingest-Hosts (`api_host_forms.release_id`).

## Vertragsrunde 4 (30.10.2026, VORGESCHLAGEN, nicht ausgeführt)

Kryptoreview `docs/paritaet/review-krypto-adapter.md` eingearbeitet: `legacy-adapter.md` (A1 Idempotency-Key im Signaturtext, `adapter_replays`, Retention; A3 Signalstärke; A4 Textkanon, leere Zeile statt `-`; A5 Schlüsseleindeutigkeit; A6 kein Cache, Pin-Überlappung; A2 nur als Fakt), `README.md` (D1 HMAC-Digest pro Formular, D2 Kollisionsablehnung, D3 Ganzzahlschlüsselregel korrigiert, D4 Surrogate/NUL, D5 Signiererart; Vektoren i–l), `ingest.openapi.yaml` (TransportEnvelope: keyVersion-Maximum, Timestamp-Pattern, Hinweis Idempotency-Key). Signaturtext des Adapters hat eine neue Zeilenfolge (Idempotency-Key ergänzt, bodyHash zuletzt): Implementierungen müssen daran angepasst werden. Offen und nicht entschieden: A2, T3 (`docs/handoffs/vertragsrunde-4-offen.md`).
