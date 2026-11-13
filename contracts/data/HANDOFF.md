# Übergabe P2 – data

SPDX-License-Identifier: AGPL-3.0-only.


## Technische Reviewkorrekturen 27.10.2026

Status: **VORGESCHLAGEN als Vertragsentwurf**, keine Produktimplementierung oder
neue Nutzerentscheidung. Enger Auftrag ausschließlich unter `contracts/`.

### Änderungen

- H01: `resource_versions`, Generations-UUID/Uniqueness, explizite Importzuordnung und durchgehende synthetische SQL-/Admin-/Flow-ID-Fixture.
- H03: anonyme/gebundene Sessions, getrennte ID/Tokenhash, Auth-/Faktorzeiten, Rechteversion, Challenges/Enrollmentreferenzen, TOTP-Replay und Publikationsbestätigungen im DDL.
- H06/H08/H10: Generation am Objekt; Checkpoint-, Debug- und Metadatenrollen mit Referenzen/TTL/Revision; Gesamtinventar und atomare Holdregeln.
- M01/M03: totale Zustands-/Modusabbildung, Lauf-/Effektslots, Release-/Modusbindung und eigener Aktionsledger.
- Dateien: `schema-entwurf.sql`, `schema-entwurf.md`, `migration-mapping.md`; neu `abbildung.md`, `objektinventar.md`, `identity-example.json`, `VALIDIERUNG.md`, dieses `HANDOFF.md`.

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

- H02: feste Autorisierungsrollen durch Vorlagenherkunft ersetzt; geschlossener Rechtekatalog (28 Einträge), Gruppen, Gruppenrechte und scoped Einzel-/Gruppenzuweisungen mit Revision/Widerruf im DDL; FK weist unbekannte Rechte ab.
- H04: UNIQUE Ansichtshost; eigene api_hosts/api_host_forms für gemeinsame signiert aufgelöste API-Hosts.
- H05/H11/M02: transport-Keyzweck/Replayledger, befristete legacy_adapter_bindings und Formular-validierungsprofil samt unveränderlichem Adapterverweis.
- H07/H09: menschliche Fortsetzung, einmaliger Resume-Beleg, Crashzustand, verschlüsseltes Originalversandmanifest und source_submission_id für separaten Neuversand angeschlossen.
- M04: gesamter Altbestand origin=legacy ohne neue 13-Monatslöschung; IP-Bezug nicht importieren, prüfen und als OFFEN melden; Objektmetadaten ebenfalls von Neufrist getrennt.
- M05: oauth_clients/grants/codes/refresh_tokens und mcp_tokens mit Hashformat, Ablauf, Verbrauch, Ersetzung/Widerruf, Herkunft und Bezügen; Migrationsmapping ohne Neufreigabe-Zwang. Hash-/Formatprüfung ausdrücklich OFFEN, keine Secrets.
- Dateien: schema-entwurf.sql, schema-entwurf.md, migration-mapping.md, abbildung.md, objektinventar.md, VALIDIERUNG.md, dieses HANDOFF.md. DDL bleibt nicht ausgeführter Entwurf.

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

- `schema-entwurf.sql`: `domain_bindings` mit Release/Ansicht-FK, Revision, Audit-Beleg (R01); `adapter_signers`, `legacy_adapter_bindings.service_cert_sha256` ohne `signature_key_version` (R03); `form_versions.transport_policy` (R05); `permission_catalog` +`test-target.manage` (R04); `stored_objects.payload_sha256` (R07); `oauth_*.resource_binding`, `oauth_codes.revoked_at`, `ck_refresh_family` (R08); `legacy_statistics.has_gclid/has_user_agent` (M04). Alles ENTWURF, **nicht** gegen MariaDB ausgeführt.
- Neu: `resend-manifest.schema.json` und `resend-manifest.example.json` (R07), mit dem venv-Python gegen das Schema geprüft.
- `objektinventar.md` (R07: drei Werte pro Objekt, Referenzregel, Prüfreihenfolge), `abbildung.md` (R01/R03/R05/R06/M03), `migration-mapping.md` (R08 Legacyprofil, M04 Projektion, M05 Besitztabelle).
- Hinweis: Forward-Referenzen der Draft-DDL (z. B. spätere Tabellen) sind wie bisher nicht in eine ausführbare Reihenfolge gebracht.

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

D1, D4, D5, D7, D9. Altquellformate (Hash/Pepper/PKCE) am echten Bestand prüfen; DDL gegen Zielversion testen; Zwei-Replika-Test für Domainwechsel.

## ADR 0005 Einarbeitung (29.10.2026, VORGESCHLAGEN, nicht ausgeführt)

- D1: `schema-entwurf.sql` `api_host_forms` um `release_id` (NULL = ungebunden), `binding_revision`, `changed_by/changed_at`, `confirmation_audit_id` und FK auf `releases` erweitert; `abbildung.md`/`schema-entwurf.md` ergänzt.
- D4: Entfernt: `resource_binding`, `legacy-unbound`, `ck_refresh_family`, Tokenübernahme-Zeilen im `migration-mapping.md` (Zeilen als "nicht übernommen" markiert), `origin` der OAuth-/MCP-Tabellen nur `'native'`, `family_id NOT NULL`, `oauth_codes.revoked_at` bleibt.
- D7: Altstatistik komplett inklusive möglicher IP-Bezüge, nur `origin='legacy'`, geschützte Hülle (`metadata_object_id`), Flag `has_ip_reference` neu neben `has_gclid/has_user_agent`; Bestandsprüfung am Dump ist Importvoraussetzung; Importbericht ohne Originalwerte; keine Personenebenenauswertung.
- Offene Rückfrage (aus ADR-Wortlaut abgeleitet): Fallen handerzeugte Alt-`mcp_tokens` unter D4? Vertrag nimmt ja an (nicht übernommen).
- Offen weiter: D5, D8-D11; Schema der Bestandsprüfung (Berichtsformat) ist Folgearbeit.

## Vertragsrunde 4 (30.10.2026, VORGESCHLAGEN, nicht ausgeführt)

Dokumente: `objektinventar.md` (M1 Prüfschritt 2a und Pin, M2 Grenze von `payloadSha256` gegen DB-Schreiber, M3 Validierungsregeln, M4), `resend-manifest.schema.json` (Pattern gegen Steuerzeichen; Datei neu formatiert), `abbildung.md`, `../crypto/migration.md`.

**DDL-Änderungen in `schema-entwurf.sql` (backend/db/check.sh neu laufen lassen, falls `backend/db/schema-p3.sql` nachgezogen wird; nicht ausgeführt):**
1. `form_protocol_keys.purpose` ENUM um `'digest-hmac'` erweitert.
2. `ingest_idempotency`: neue Spalte `digest_key_generation`, CHECK `digest_evidence` erweitert (verified ⇒ Generation gesetzt, legacy-missing ⇒ NULL); `request_digest` bleibt Spaltenname, Inhalt jetzt HMAC.
3. `workflow_runs`: neue Spalte `digest_key_generation BIGINT UNSIGNED NOT NULL` (Insert-Statements in `check.sh` müssen sie liefern).
4. `legacy_adapter_bindings`: `service_cert_sha256_next BINARY(32) NULL` plus CHECK `<>` aktueller Pin.
5. `adapter_signers`: `UNIQUE KEY uq_adapter_signer_pubkey (public_key)`.
6. Neue Tabelle `adapter_replays` (PK `(binding_id,text_sha256)`, CHECK `expires_at >= created_at + INTERVAL 600 SECOND`, FK auf `adapter_signers` und `legacy_adapter_bindings`).
7. `submissions`: Spalte `mail_manifest_payload_sha256`, CHECK `ck_submission_manifest_pin`; nach dem `payload_sha256`-ALTER: `stored_objects` UNIQUE `uq_stored_object_payload` und FK `fk_submission_manifest_pin`.

Reihenfolge der ALTERs beachten (Pin-FK steht hinter dem `payload_sha256`-ALTER). Syntax (insb. Intervall-CHECK) nicht gegen MariaDB geprüft. `backend/db/schema-p3.sql` unverändert (nicht im Besitz dieses Pakets).
