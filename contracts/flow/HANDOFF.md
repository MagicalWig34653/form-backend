# Übergabe P2-4

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

## Ergebnis und Dateibesitz

Abgeschlossenes Vertragspaket unter `contracts/flow/`: zwölf Draft-2020-12-Schemas,
21 synthetische Beispiele mit Manifest, README, separates Sandbox-Anforderungspaket
und ausführbares Offline-Prüfskript. Alle Detailvorschläge tragen den Status
VORGESCHLAGEN; bestätigte Anforderungen und abweichender Altbestand sind im README
zugeordnet. Keine Produktimplementierung, kein Deployment, keine Migration.

Ein schreibender Agent; keine Delegation und keine weiteren Dateireservierungen.
Arbeitsverzeichnis: Projektwurzel `form-backend`, bestehender Checkout auf `main`.
Kein neuer Branch/Worktree: Der Nutzer hat Schreiben ausschließlich unter
`contracts/flow/` gestattet, daher keine Git-Metadatenänderung. Vor Arbeitsbeginn
lagen bereits unversionierte Projektdateien vor; keine davon übernommen, gelöscht
oder committed. Altprojekt nicht geöffnet oder ausgeführt, keine Secrets oder
Kundendaten verwendet. Keine laufenden Jobs oder Hintergrundprozesse dieses Pakets.

STATUS, ARBEITSPLAN und ADRs bleiben wegen der ausdrücklichen Verzeichnisgrenze
unverändert. Die Koordination muss diesen Fortsetzungsstand dort nach Review
verlinken und die Detailvorschläge gegebenenfalls als Entscheidung übernehmen.

## Tatsächlich ausgeführte Prüfungen

`python3 contracts/flow/validate.py`, lokal mit `jsonschema 4.26.0` und `referencing`:

- Zwölf Schemas gegen die Draft-2020-12-Metaschemata geprüft; alle lokalen
  statischen `$ref` aufgelöst, auch unbenutzte Zweige; doppelte JSON-Schlüssel
  würden vom Prüfskript abgewiesen.
- 21 Beispiele gegen zugeordnete Schemas validiert; zusätzliche Fixture-Prüfungen
  für Hashbindung, Graphen, fixierte Feldwerte, verborgene Ansichts-Felder,
  Checkpointbezüge, Leasezeit und Debug-TTL bestanden.
- 41 gezielte Negativfälle erwartungsgemäß abgelehnt; unter anderem fehlende
  Sandbox, unkontrollierter Zyklus, fehlende/ungültige Lease, überschrittenes
  Budget, Klartextcheckpoints, automatischer Mail-Retry, unmaskierter Debugwert,
  falsche TTL, IP-Statistik und Credential-Eigenschaften im Importpaket.

Keine Abhängigkeiten installiert und keine Netzwerkabrufe. Optionales RFC3339-
Extra ist lokal nicht verfügbar; Syntax/Kalenderprüfung wurde im Prüfskript
explizit ergänzt (keine historische Schaltsekundenprüfung). Das Skript prüft
Fixture-Semantik, nicht die Korrektheit einer Engine oder die sichere Erkennung
beliebiger versteckter Secrets in Quelltexten/Vorlagen.

## Offene Grenzen und nächster Schritt

1. Koordinationsreview: Detailnamen/Versionierung, Typnormalisierung und
   Bestandsadapter, Grenzen/Fristen, Idempotenz-Hashbildung/Retention,
   Effekttransaktionen/Retry und Moduldeaktivierung bestätigen oder ändern.
2. Abgleich mit parallelen P2-Paketen für Rechte, Krypto, Eingang/Upload,
   Speicheradapter, Signaturen und Audit; diese Verträge nicht still ersetzen.
3. Debugauftrag/Klartextzugriff und bestehende Ads/GCLID-/Statistikmigration
   separat spezifizieren. Keine Bestandskennzahlen durch neuen Ereignisvertrag
   löschen. Löschprotokoll gehört in den Auditvertrag.
4. P6 zuerst Engine ohne Skripte; anschließend eigenes P6-S mit verbindlichem
   Sandboxprofil-/IPC-Vertrag, Implementierung, Angriffs-/Ressourcenprüfungen
   und unabhängigem Sicherheitsreview. Das deklarierte synthetische Sandboxprofil
   ist absichtlich unaufgelöst; Skriptgraphen sind noch nicht veröffentlichbar.
5. DB-/Mehrworker-/Absturz-/Idempotenz-/Resendprüfungen mit synthetischen Daten
   erforderlich. JSON-Schema-/Fixtureprüfungen sind keine Integrationsabnahme,
   kein Sicherheitsnachweis und keine Aussage zur Produktionsreife.


## Technische Reviewkorrekturen 27.10.2026

Status: **VORGESCHLAGEN als Vertragsentwurf**, keine Produktimplementierung oder
neue Nutzerentscheidung. Enger Auftrag ausschließlich unter `contracts/`.

### Änderungen

- H01: gemeinsame UUID-/kid-/Ressourcenreferenzen in `common.schema.json` und betroffenen Formular-/Ansicht-/Graph-/Release-/Lauf-/Debug-/Statistikschemas; portable Artefakt-/Knoten-IDs getrennt; Beispiele/Hashreferenzen aktualisiert.
- H06: `security.customerKeyGeneration` aus Schema und Beispielen entfernt; Generation am Objekt.
- M01/M03: uncertain darstellbar, runSlot/effectSlot und eigener interner Idempotenzscope.
- M02 (Technik): vier reservierte Technikfeldnamen als Fachfeld ausgeschlossen.
- M07: portables ASCII-Regex ohne Inlineflag; Sandboxfreigabe bleibt gesperrt.
- L01: nur 16–32 Hexbytepaare, Byteabbildung dokumentiert.
- Dateien: genannte Schemas, `examples/*.json` (außer unverändertem Manifest), `README.md`, `validate.py`, dieses `HANDOFF.md`.

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

- H02: flow.execute/approve/resume am gemeinsamen Rechtevertrag angeschlossen; bekannte Freigabe-/Fortsetzungsrechte im Graph-/Laufschema.
- H05: sym-v2 als auswählbares Speicherprofil im Formschema gesperrt; eigener Transportvertrag referenziert.
- H07/H09: neuer wiederanlauf.md mit menschlicher Freigabe nach Warten/Crash, unverändertem Originalresend, flüchtigem CEK-Prüfvorschlag und getrenntem bearbeitetem Neuversand. continuationPolicy verpflichtend, crash-recovery zusätzlich zu manual-resend darstellbar.
- M02/M04: Legacyvalidierungsadapter und Herkunft legacy ohne Neufrist angeschlossen.
- Dateien: README.md, neu wiederanlauf.md, form.schema.json, graph.schema.json, execution.schema.json, examples/execution.json, examples/execution-manual.json, examples/execution-paused.json, examples/execution-waiting.json, validate.py, dieses HANDOFF.md. Kein neues Manifestbeispiel; Crashfixture zusätzlich im Prüfer erzeugt.

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

- R02 behoben: `wiederanlauf.md` Abschnitt R02 (Abrufpfad Browser→Resume→Worker, Rechte-Unterscheidung, neuer Lauf mit Nachweis).
- R05: `form.schema.json` `security.transport` (`off|offered|required`, Standard `off`); `validate.py` +3 positive, +2 Negativfälle.
- R07: `common.schema.json` `protectedRef`-Beschreibung (Schnappschuss, keine dauerhafte Identität).
- M07 teilweise: `SANDBOX-ANFORDERUNGEN.md` Schemaprofil/Regex/Capability/Profilfelder als Vorschlag; Runtime bleibt offen (D10), Skriptsperre unverändert.
- Redaktion: `README.md` Scheduler markiert nur Fälligkeit (ADR 0004).

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

D3, D10. Synthetischer Gesamtpfad Browser→Resume→Worker; Sandboxreview.

## ADR 0005 Einarbeitung (29.10.2026)

README: Altstatistik-Satz auf D7 angepasst (mögliche IP-Bezüge geschützt übernommen). Keine Schemaänderung; D1 betrifft `PublishInput.rebind` (auth-Vertrag). Release-Schema unverändert.
