# Übergabe P2-2

26.10.2026 · SPDX: AGPL-3.0-only.

## Paket, Dateibesitz und Stand

Ziel: normative Kryptoverträge aus ADR 0001–0003, P0-D samt Review und gezielten Altcodebelegen; keine Implementierung. Dateibesitz ausschließlich `contracts/crypto/`, ein schreibender Agent (Codex), keine Unterdelegation. Dateien: README.md, paket-v2.md, schluessel.md, migration.md, signatur.md, test-vectors.md, HANDOFF.md. Abnahmeumfang: bytegenaue :2-Formate/Suite, Schlüsselmodell, normalisierte Recovery, Umhängen, isolierte Altleser, Signatur-Kanonisierung, Fehlergrenzen und reproduzierbarer Vektorplan.

Arbeitsverzeichnis: `<workspace>/form-backend`, vorhandener Branch `main`, gemeinsamer Checkout; kein eigener Worktree/Branch/Commit angelegt. Der anfängliche Checkout zeigte die Projektdateien als untracked. Nutzerauftrag begrenzt sämtliche Schreibzugriffe auf `contracts/crypto/`; deshalb keine Änderung von STATUS/ARBEITSPLAN/ADRs oder Git-Metadaten. Dieser Handoff hält den Fortsetzungsstand innerhalb des erlaubten Bereichs fest. Keine gestarteten Dienste, Hintergrundjobs oder delegierten Schreibpakete aus P2-2.

## Prüfungen und Grenzen

AGENTS, STATUS, ARBEITSPLAN, ENTWICKLUNG, ADR 0001–0003, SICHERHEIT-UND-DATEN, PARITAET, D und review-D gelesen; gezielt mit den in den Verträgen genannten Altquellen und P2-1 abgeglichen. Nur Lesewerkzeuge auf Altquellen, kein Alt-PHP/JS/Test/Build/Docker ausgeführt, `secrets/` und produktive Schlüssel/Daten nicht geöffnet, keine Schlüsselwerte übernommen. Vom öffentlichen HPKE-Fixture ausschließlich `_quelle` ausgewertet. Statische Prüfung der lokalen Dokumentlinks und Pflichtinhalte durchgeführt; abschließender konkreter Prüfstand siehe unten. Keine kryptografischen Verhaltenstests, keine erzeugten Fixtures, kein Build/Testbefehl im neuen Gerüst. Noch kein unabhängiges Review; keine Produktionsfreigabe.

## Offene Prüfaufträge

| ID | Blockierter Bereich / nächster Nachweis |
| --- | --- |
| K01 | AES-Schlüsselanpassung bei rohen v1-Strings: synthetische Bibliotheks-/Kreuzprüfung, voller HMAC-Key bleibt belegt. |
| K02 | RSA-OAEP-Digest, MGF1 und Label: synthetischer Versionsnachweis und explizit parametrisierte Gegenprüfung. |
| K03 | RSA-PEM-Container, Cipher/KDF, benötigte Bestandsvarianten: synthetischer Export und autorisierter Importnachweis. |
| K04 | Bedeutung der zusätzlichen symmetrischen Nutzlasthülle in ADR 0003: Paket-sym oder eigener Transportvertrag. |
| K05 | Gemeinsame HTTP-/MCP-Fehlerzuordnung einschließlich JSON-Exception mit P2-1/P2-5. |
| K06 | `kid`-Kollisionen und identische Alt-`kid` im Kundenmodell mit P2-3. |
| K07 | Zuordnung globaler Altgenerationen zu Kunden, Zugangsrechte und Auswirkungen globaler Kontosperrung mit P2-3/P2-5. |
| K08 | Kunden-/Kontonamensraum der Browserablage und Cutover lokaler Altbünde. |
| K09 | Vollständiges Referenzinventar für Rotationsabschluss, auch externe Speicher/Anhänge. |
| K10 | Nicht migrierbare Altzeilen/Ausnahmen vor Cutover; kein Altdecoder in der Laufzeit. |
| K11 | Neuer serverseitig verwendbarer MFA-Speichervertrag samt Schlüsselhaltung und Migration mit P2-5. |
| K12 | Alt-SDK-/Adaptergrenze unter ADR 0001, keine implizite Freigabe globaler Altdecoder. |
| K13 | PHP-Parser-/Typ-/JSON-Grenzfälle mit PHP/Swift/Browser-Vektoren abnehmen. |
| K14 | Befristung und genaue Vergabe-/Widerrufssemantik der Signaturausnahme bestätigen. |

Es wurden keine unbelegten OAEP-/AES-/PEM-Defaults festgelegt. Weitere offene Produktdetails wurden nicht als Architekturentscheidungen implementiert; neue ADRs liegen außerhalb des erlaubten Schreibbereichs.

Konkreter statischer Prüfstand: sieben Markdown-Dokumente, 14 lokale Dokumentlinks vorhanden, Lizenzhinweise und geschlossene Codeblöcke geprüft; K01–K14 sowie Pflichtbegriffe für Suite, Formate, Recovery und Kanonisierung vorhanden. Kein statischer Prüffehler. Ergänzender Quellenabgleich zu Zugangserteilung, Wrap-Lebenszyklus, Recovery-Audit und Schutz des letzten Adminzugangs auch zur auslaufenden Generation durchgeführt. Diese Prüfungen ersetzen keine Verhaltens-/Integrationsprüfung.

Nächster Schritt für die Koordination: P2-1/P2-3/P2-5 gegen diese Verträge prüfen, K04/K07/K11/K12 und die übrigen zuständigen Beschlüsse klären, unabhängiges Vertragsreview durchführen. Danach gesondert autorisierte isolierte Vektorerzeugung und P3-Kreuz-/Integrationsprüfung gemäß test-vectors.md. STATUS/ARBEITSPLAN durch die Koordination aktualisieren.


## Technische Reviewkorrekturen 27.10.2026

Status: **VORGESCHLAGEN als Vertragsentwurf**, keine Produktimplementierung oder
neue Nutzerentscheidung. Enger Auftrag ausschließlich unter `contracts/`.

### Änderungen

- H01/H06: UUID↔Kunde/kid/Generationsnummer und aktive Generation am Objekt in `schluessel.md` verknüpft.
- H08/H10: gemeinsames Inventar, Rotationsabschluss und vollständige Holdliste in `schluessel.md` angeschlossen.
- M02 (Technik): Reihenfolge und Technikfeldausschluss in `signatur.md` festgehalten.
- Dateien: `schluessel.md`, `signatur.md`, dieses `HANDOFF.md`.

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

- H05/K04: eigener symmetrischer Transportvertrag in neuem transport.md (Wireformat, AAD, Nonce, Ed25519, Formular-Keygeneration, Replay, Grenzen); technische Details VORGESCHLAGEN. Speicherprofil sym-v2 bleibt gesperrt, Paket-wrap=sym/Nachschutz getrennt.
- H11/K12: Ausnahme für isolierten befristeten Headeradapter nach ADR 0004 angeschlossen; keine globalen Keyfallbacks oder Altdecoder im Kern.
- H07/H09: flüchtiger objektspezifischer CEK-Originalnachweis im Wiederanlaufvertrag referenziert; kein dauerhafter Klartext/Entschlüsselungsschlüssel.
- Dateien: README.md, migration.md, paket-v2.md, schluessel.md, neu transport.md, dieses HANDOFF.md. K04/K12 sind als Produktfrage entschieden, technische Abnahme bleibt offen.

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

- R04 behoben (Krypto-Anteil): `schluessel.md` ersetzt feste Adminbegriffe durch `key.manage`/Datenzugang/Schutz der letzten handlungsfähigen Identität; Abschnitt R04 mit Aktionstabelle.
- R03 (Krypto-Anteil): `signatur.md` – getrennte Signierer (nativ vs. Adapter), kein Fallback, Ausnahme nur nativ.
- R05 teilweise: `transport.md` – Politik `off/offered/required`, Voraussetzungen, kein Downgrade, Provisionierung/Provider OFFEN (D3).
- R06: Digestanschluss verweist auf `../ingest/README.md`; Hüllenhash nie Teil des Digests.

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

D2, D3, D8. Unabhängiges Kryptoreview für `KUBUS-ADAPTER-SIGN-1` und die Transportpolitik; keine Vektoren/Laufzeit ausgeführt.

## ADR 0005 Einarbeitung (29.10.2026)

Keine Vertragsänderung im Kryptoteil. D2 (`KUBUS-ADAPTER-SIGN-1` braucht Kryptoreview) und D3 sind unverändert; D8 offen. D4: kein Hashformat-/Pepperimport für OAuth/MCP mehr nötig (entfällt als Prüfauftrag).

## Vertragsrunde 4 (30.10.2026, VORGESCHLAGEN, nicht ausgeführt)

`signatur.md`: Kanon (Pfadliterale, UUID/Timestamp/Integer, leere Zeile als Platzhalter), strikte Ed25519-Verifikation, Replay nie über Signaturbytes, Registereindeutigkeit (A4, A5, A7). `transport.md`: Idempotency-Key in AAD und Signaturtext (T1), Replay-Retention `max(timestamp+300, Reservierung+300)+60 s` (T2), Veröffentlichung braucht Transport- und Ed25519-Schlüssel (T4), kanonische Ganzzahl-/UUID-Regeln (T5), Nonce-Obergrenze und Body-Limit vor Hashing (T6). `migration.md`/`test-vectors.md` ergänzt (M4, Pflichtvektoren, nicht erzeugt). AAD/Signaturtext der Transporthülle ändern sich (neue Zeile): vor Implementierung noch kein Wirevertrag. Offen: T3 Antwortauthentisierung und A2 (`docs/handoffs/vertragsrunde-4-offen.md`); Kryptoreview der geänderten Texte steht aus.
