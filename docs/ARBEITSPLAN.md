# Arbeitsplan

## Umstieg: Plan automatisch (11.11.2026, Todolino 1EA2CCBB)

Umgesetzt im Worktree-Branch `worktree-agent-a0c0903c0d8bc9dce` (ADR 0040, `docs/handoffs/Umstieg-Plan-automatisch.md`). Nächste Schritte: unabhängiges Review, Merge, Image-Update und danach den Prüflauf mit der echten Quelle wiederholen. Zeigt die Schlüsselliste eine Warnung „nicht im Altbestand“, muss das vor dem Import im Altsystem geklärt werden. Offen als eigene Entscheidung: wie Einsendungen ohne vorhandene Schlüsselgeneration behandelt werden (heute bricht der Lauf ab) und die Zielnummern bei vorhandenen Zielkunden.

## HTML-E-Mail-Builder (11.11.2026)

Umgesetzt im Worktree-Branch `worktree-agent-aafdd4bb248d0ad0a` (siehe `docs/handoffs/Mail-Builder.md`). Nächste Schritte: unabhängiges Review (Sanitizer, URL-Regeln, Moduswechsel), Merge, Testversand einer Design-Mail an Outlook und Gmail. Später optional: Bild-Upload, Vorlagenbibliothek, Vorschau externer Bilder (`img-src https:` in der CSP).

## DB-Pool-Deadlock (11.11.2026, Todolino 1EA2CCBB)

Erledigt im Worktree `worktree-agent-aa30f66e51e219486`. Offen sind Review, Merge, Image-Update und ein wiederholter Umstieg im Betrieb. Folgearbeit (nicht begonnen): Hintergrunddienste so umbauen, dass sie nicht mehr eine Sitzung halten und darin eine zweite Verbindung anfordern, sondern eine eigene Lock-Verbindung nutzen oder nur über die Lock-Sitzung arbeiten. Optional ENV für die Pool-Größe (Registry und Deploy-Vorlagen). Details: `docs/handoffs/DB-Pool-Deadlock.md`.

## Einsendungen/Export — Abnahmepaket (03.11.2026)

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

## P12-A UI-Merge – abgegrenzte Nachkorrektur (03.11.2026)

Paket `fix-ui-seam`, Worktree `form-backend-seam`, ein schreibender Codex ohne
Delegation: Dateibesitz `pwa/e2e/admin.spec.ts`, STATUS/ARBEITSPLAN und
`docs/handoffs/P12-A-Seam-Fix.md`. Abnahme: exakter Speichern-Selektor,
queryunabhängige Listen-/Exportmocks, Check/Lint/Vitest; Browserlauf ausschließlich
beim Nutzer. Keine UI-/API-/Architekturänderung, kein Commit. Befunde und aktueller
Prüfstand im Handoff: Check/Lint/104 Vitest/diff --check bestanden, Dateibesitz
frei, keine laufenden Jobs. Nächster Schritt beim Nutzer:
`cd pwa && npx playwright test e2e/admin.spec.ts`.

Stand 25.10.2026: ausschließlich Gerüst/Planung. Keine aktive Implementierung zugewiesen.

## Empfohlene Reihenfolge

| Paket | Ergebnis | Rolle | Abhängigkeit |
| --- | --- | --- | --- |
| P0 | Vollständige Funktions-/Daten-/Routenmatrix des Altbestands | Sonnet oder Codex | lesender Zugriff auf Altprojekt |
| P1 | Offene Grundentscheidungen, Profil-/Ablaufsemantik und Modulgrenzen | Sonnet mit Claude-Koordination | P0, Nutzerentscheidungen |
| P2 | Minimale gemeinsame API-/Ereignis-/Paketverträge und synthetische Beispiele | Sonnet oder Codex | P1 |
| P3 | Technischer Durchstich Swift–MariaDB–PHP–Browser, Krypto und Passkey-Kompatibilität | Codex oder Sonnet; unabhängig prüfen | P2 |
| P4 | Backend-/PWA-Grundaufbau mit reproduzierbarem Build/CI und synthetischer Umgebung | Sonnet/Codex parallel nach Dateibesitz | P3 |
| P5 | Ein vollständiges Formular: Konfiguration, Ansicht, Eingang, verschlüsselte DB, Mail, Statistik | Sonnet/Codex | P4 |
| P6 | Versionierte Ablaufengine, kleiner Bausteinkatalog, Ablaufeditor und Debug | Sonnet/Codex | P5, früh festgelegte Engineverträge |
| P7 | Legacy/v2-Adapter, PHP-SDK, Pairing, Domainzuordnung und Guide | Sonnet/Codex | passende Kernverträge |
| P8 | Alle Bestandsfunktionen, Import/Export, MCP-Konfiguration, S3/SFTP | einzelne abgegrenzte Pakete | P0-Matrix, Kernmodule |
| P9 | Wiederholbare Datenmigration, Paritätsprüfung und Cutover-Probe | Codex/Sonnet, unabhängig reviewen | P0–P8 |
| P10 | Mehrreplika-/Wiederanlauf-/Lasttests, Recovery, Betriebsabnahme | Sonnet/Codex | integriertes System |

Haiku übernimmt darin klar begrenzte Zuarbeit mit festem Muster, keine pauschalen Gesamtpakete. Reihenfolge bei neuer Erkenntnis ändern und begründen; spätere Pakete weiter zerlegen.

## Stand der Pakete (26.10.2026)

P0: Erhebung erledigt (`docs/PARITAET.md`), B-Review liegt vor, Korrektureinarbeitung offen. P1: Grundentscheidungen beschlossen (ADR 0001–0003). P2: Vertragsentwürfe fertig (`contracts/`), unabhängiges Review erledigt (19 Befunde, `docs/paritaet/review-P2-vertraege.md`; technische Korrektur läuft per Codex), Nutzerentscheidungen Nr. 20–30 offen, Nutzerbestätigung Nr. 20–22 offen. P3: nächstes Paket, nicht begonnen. P6 wird wegen des vollen Editors in Engine ohne Skripte und separate Skriptsandbox zerlegt. Delegationsvorgabe des Nutzers: ca. 75 % Codex (`gpt-6.1-sol`), Claude als Fallback, siehe ENTWICKLUNG.md.

## Nächster sinnvoller Auftrag

P0 rein lesend durchführen und eine geprüfte Paritätsmatrix erstellen. Parallel dazu können offene Produktentscheidungen besprochen werden. Keine Produktimplementierung aus dem bloßen Vorhandensein dieses Gerüsts ableiten.

## Verbindliche Vorgaben für alle Pakete

Repository als alleinige Source of Truth; Sessions sind wegwerfbar. Fortschritt und fortsetzungsrelevante Ergebnisse im selben Arbeitsschritt dokumentieren. Vor Übergaben/Kontextwechseln einen vollständigen knappen Fortsetzungsstand sichern. Projektlizenz: AGPLv3 (AGPL-3.0-only); LICENSE und erforderliche Fremdlizenzhinweise erhalten.

## Stand 30.10.2026

P0–P2 erledigt bzw. Vertragsentwurf mit Reviews; P3 (Krypto, Schema, Passkey) und P4-A/B (Backend-/PWA-Grundgerüst) umgesetzt und getestet; Code-Review-Korrekturen laufen. P5–P10 offen. Maßgeblich: `docs/FORTSETZUNG.md`.

## P5 Zerlegung (30.10.2026)

P5 ist zu groß für ein Paket. Reihenfolge, je Paket exklusiver Dateibesitz:
- **P5-A Ingest-Kern** (läuft, Claude implementer, Codex-Limit bis 04.11.): Eingangsendpunkt nach `contracts/ingest/ingest.openapi.yaml` (nur v2-Pfad, Adapter inaktiv laut ADR 0006): Signatur-/Zeitstempelprüfung, Idempotenz, Ablage des verschlüsselten Pakets in MariaDB (`stored_objects`, `ingest_idempotency`). Besitz: neues Target `backend/Sources/FormIngest/`, `backend/Tests/FormIngestTests/`, `Package.swift`-Eintrag, `docs/handoffs/P5-A.md`. Nicht: Mail, Statistik, UI, Ablaufengine.
- P5-B Formular-Konfiguration/Release (Admin-API-Ausschnitt), P5-C Mail-Versand aus verschlüsseltem Eingang (Resend-Manifest), P5-D Statistik-Ereignis, P5-E PWA-Ansicht: erst nach P5-A und Review.
- Login/Passkey-Route (R2 aus `review-code-korrektur-backend.md`) gehört zu P5-B/Auth, nicht zu P5-A.

Stand 31.10.2026 (P5): P5-A Ingest fertig (Review-Befunde B1/B2 behoben, B3–B8 offen). P5-B1 Auth-Kern (`FormAuth`: Passkey-Login, Zweitfaktor Passwort, DB-Sitzung/CSRF, Throttles, Rechteprüfung) funktional fertig und getestet, Review offen (`docs/handoffs/P5-B1.md`). P5-B2a (`FormAdmin`: listForms/createForm/getForm) fertig (`docs/handoffs/P5-B2.md`); Entwürfe/Release warten auf F2/F3/F8 und RFC-8785-Kanonisierung. P5-C Mail, P5-D Statistik, P5-E PWA-Ansicht offen. Agent-Starts wurden vom Classifier abgelehnt; B1/B2a hat der Koordinator selbst umgesetzt.

Stand 31.10.2026 (P5-C): Mailversand mit Inhalt umgesetzt (ADR 0010, `docs/handoffs/P5-C.md`). P5-D Statistik und P5-E PWA-Verwaltungsansicht offen.

Stand 31.10.2026 (P5-E): PWA-Verwaltungsoberfläche umgesetzt (`docs/handoffs/P5-E.md`): Router mit Pfadparametern (`/t/{kunde}/f/{formular}/{tab}`), Sitzungsstore, Seiten Kunden, Formulare, Formular (Überblick, Felder, Mail, Veröffentlichen, Schlüssel & SDK), Verbindungen. Offen in P5-E: Konten-/Rechteverwaltung, Passkey-Verwaltung, Browser-Schlüsselverwaltung, Statistik (P5-D), manueller Mail-Resend.

Stand 31.10.2026 (P5-F): Einsendungen lesen und im Browser entschlüsseln umgesetzt (`docs/handoffs/P5-F.md`). Offen in P5: Browser-Schlüsselverwaltung (PRF/Datenzugang/Recovery), P5-D Statistik, manueller Mail-Resend, Konten-/Rechte-/Passkey-Verwaltung, Review.

## Neuer Wunsch (02.11.2026): SDK-Selbstupdate durch das Backend (P7-U, nicht begonnen)
Das Backend soll das PHP-SDK beim Kunden aktualisieren können: Zugangsdaten (FTP/SFTP) und genauer Zielpfad je Kunde/Formular hinterlegen (Secrets verschlüsselt wie `managed_secrets`), Version prüfen, hochladen, Rollback auf die vorherige Version. **Auto-Updates sind optional** (pro Kunde/Verbindung abschaltbar, Standard aus; manuell auslösbar). Offene Entwurfsfragen: Integritätsnachweis des SDK-Pakets (Signatur/Hash, Pinning), Atomarität (neues Verzeichnis + Umbenennen/Symlink statt Überschreiben), Verträglichkeit mit Hostern ohne Rename, Schutz vor Downgrade-Angriffen, Test-Aufruf nach Update (Smoketest-Einsendung), Audit, Zielschutz (SSRF/HostGuard für FTP-Ziele), Verhältnis zu den S3/SFTP-Verbindungen aus P8. Wird als eigenes Paket mit ADR und Review angelegt.

## Stand 02.11.2026 (P8-A)
P8-A Löschung/Hold/Aufbewahrung/Chiffrat-Export im Backend umgesetzt (ADR 0012, `PrivacyTests`). Nächste P8-Pakete in dieser Reihenfolge: P8-A-UI (PWA: Löschen, Hold, Frist, Export-Download mit lokaler Entschlüsselung), Webhooks, Debug/Testziele, MCP/Tokens, S3/SFTP-Speicher, Domainzuordnung (P7). Danach P6, Rotation (inkl. Hold-Rewrap), P9, P10, externes Audit.

## P-Rotation (03.11.2026, Worktree feature-rotation)

Ziel: kundenbezogene Datenschlüsselrotation, CAS-Rewrap aller Inventarrollen, Abschluss bei null Referenzen, Zugangsentzug aller Generationen und atomarer Hold-Nachschutz. Vertrag: ADR 0016 und genannte Krypto-/Inventarverträge. Dateibesitz: Hauptagent Backend-Routen/Ingest/Löschsperre/Interop/Dokumentation; Browser-Agent ausschließlich pwa; Testagent RotationTests/PrivacyTests; unabhängiger Reviewer nur lesend. Keine Commits/Pushes. Abnahme: Vitest/check, Swift-Interop und DB-Tests Rechte/CAS/Races/Hold/Restreferenzen/Audit/letzte Identität. DB ausschließlich `P3B_PORT=33421 P3B_NAME=rotation-mariadb ./backend/integration-test.sh --filter Rotation`. Docker nicht erreichbar (Exit 2); endgültiger Prüfstand und nächster Schritt siehe `handoffs/P-Rotation.md`.

P-Rotation Nachprüfung 03.11.2026: Nutzer-DB-Lauf 231 Tests/1 Fehler analysiert (`/tmp/rot.log`); Hold-Test erwartete bei fehlendem Pflichtfeld irrtümlich 422 statt des Decoder-Vertrags 400. Test auf exakt 400+bad_request korrigiert und um unveränderte Pakete/Flag/Audit sowie leere Liste→409 verstärkt; Server unverändert. Dateibesitz lokal: PrivacyTests und Fortsetzungsdokumentation. Nächster Schritt nach Kompilation: korrigierten Hold-Test mit MariaDB nachprüfen; Details `handoffs/P-Rotation.md`. Keine Commits.

P-Rotation Astra-Nachprüfung 03.11.2026 abgeschlossen (Codex allein, Worktree/Branch feature-rotation): alle vier Befunde umgesetzt; Dateibesitz und Verträge in `handoffs/P-Rotation.md`, ADR 0016. Swift-Testtargets gebaut, PWA 71 Vitest/check/lint/build erfolgreich. DB-/TCP-Tests geschrieben und kompiliert, auf ausdrücklichen Auftrag nicht ausgeführt; kein Docker, Commit oder Push. Keine laufenden Jobs. Nächste Abnahme: Wiederaufnahme beider Generationen nach Zugangsverlust und große Hold-/Rewrap-Requests über echtes TCP mit MariaDB prüfen; anschließend Browser-Lock-Integration.
## P9 Importer (03.11.2026)

Paket im Worktree `form-backend-migration` / Branch `feature-migration` implementiert, ungecommittet, Abnahme offen. Besitz: `backend/Sources/FormMigration/`, `backend/Tests/FormMigrationTests/`, Target-/CLI-Anbindung in Package.swift/main.swift, ADR 0014, Handoff P9, STATUS/ARBEITSPLAN. Keine laufenden Jobs oder parallelen Schreiber. Testziel ausschließlich `P3B_PORT=33419 P3B_NAME=migration-mariadb ./backend/integration-test.sh --filter Migration`; aktuell Docker-Zugriff gesperrt, kein Test ausgeführt. SwiftPM-Dependencyauflösung fehlt; alternative Typprüfung bestätigt nur Compilerverträglichkeit gegen vorhandene Module. Nächster Schritt: ausführbarer Build und Integrationstest, unabhängiges Review, danach offene Mappingteile aus `docs/handoffs/P9.md`. P9 ist ausdrücklich noch keine vollständige Cutover-/Produktionsabnahme.

P9-Nachtrag 03.11.2026: Vom Nutzer gemeldeten Startfehler beider DB-Tests auf numerische `HEX()`-Semantik zurückgeführt; Byte-Casts und explizite UUID-Textprojektion implementiert, Fixture unverändert. Sichere Tabelle-/Spalten-Diagnostik ergänzt. SwiftPM kompiliert und linkt jetzt erfolgreich, 3 neue lokale Dekodierungs-/Diagnosetests bestanden. DB-Projektionstest ergänzt und kompiliert; MariaDB-Wiederholung übernimmt der Nutzer (`33419`, `migration-mariadb`). Dateibesitz unverändert plus `MigrationDecodingTests.swift`, kein Commit/Push, keine laufenden Jobs. Handoff P9 fortgeschrieben; nächste Aktion ist die DB-Nachprüfung, kein bestätigter DB-Erfolg.

### P9 Reviewkorrekturen (03.11.2026)

Drei beauftragte Befunde in `LegacyImporter.swift`/`Transform.swift` behoben: unbeschränkte erste Cursor-Seite einschließlich negativer IDs und Inventar-/Scan-Abgleich (`countMismatch` verhindert Verification), belegte unbekannte Formularspalten als `unmapped-column` auch bei Ledger-Wiederholung, Status/Abschlusszeit unabhängig von Berichtsänderung. Vier DB-Regressionsfälle ergänzt und kompiliert; wegen nicht verfügbarem Docker ausdrücklich nicht ausgeführt. SwiftPM-Build/Link mit lokalem Filter `MigrationDecodingTests` erfolgreich, 4 lokale Tests/0 Fehler, Diffprüfung erfolgreich. ADR 0014 und Handoff P9 aktualisiert. Dateibesitz: FormMigration-Importer/Transform, die zwei Migration-Testdateien und diese Dokumentation, keine parallelen Schreiber. Worktree `form-backend-migration`, Branch `feature-migration`, alles ungecommittet, kein Push, keine laufenden Jobs. Nächster Schritt: DB-Abnahme durch Nutzer mit `P3B_PORT=33419 P3B_NAME=migration-mariadb ./backend/integration-test.sh --filter Migration` (7 DB-/4 lokale Tests); Details/Grenzen in `docs/handoffs/P9.md`.
## P7/P8 Domainzuordnung und Ereignisstatistik (03.11.2026)

Paket in Worktree `form-backend-domains`, Branch `feature-domains`, ohne Commit/Push. Ziel/Vertrag: ADR 0015 und bestehende Domain-/Ereignisverträge. Besitz: Backend DomainRoutes/Collector, Statistik/API/Eraser/Scheduler, Ingest-Statistikkontext; PWA Statistikkomponente/DTO/Tests; vier Domain-Testsuiten. Keine Schemaänderung. Umsetzung vorhanden; Backend-/Browserlaufzeitabnahme noch offen. Testbefehl ausschließlich `P3B_PORT=33420 P3B_NAME=domains-mariadb ./backend/integration-test.sh --filter Domain`. Nächster Schritt: offene DB-/Browserprüfungen in freigegebener Umgebung ausführen, Review und SDK-/Ansichtsinstrumentierung abnehmen; keine Veröffentlichung. Tatsächliche Ergebnisse und Jobs siehe STATUS sowie `docs/handoffs/P7-P8-Domains-Statistik.md`.

## P6 Minimalkern (03.11.2026, feature-engine)

Ziel/Vertrag: Nutzerauftrag P6 ohne Skripte/Editor, `contracts/flow/`, ADR 0001–0006; Implementierungsentscheidungen ADR 0017. Umsetzung in `FormFlow`, Admin-Lauf-/Debugrouten und eng begrenzter Ingest-/Mail-/Releaseverdrahtung vorhanden; vollständige Dateiliste/Teststand in `docs/handoffs/P6.md`. Worktree `form-backend-engine`, Branch `feature-engine`, ungecommittet; alle Dateizuständigkeiten frei, keine laufenden Jobs.

Abnahme ausstehend: Docker-MariaDB (vorgeschriebener Befehl mit Port33422/Name engine-mariadb Exit2 blockiert), SMTP-/Wiederanlauf-/Zweiworkerfälle und unabhängiges Sicherheitsreview. Ohne DB erfolgreich gebaut: 52 Fälle, 19 ausgeführt, 33 übersprungen, 0 Fehler. Nächster Schritt: DB-Befehl aus Handoff ausführen. Danach vollständiges Original-Mailmanifest (Mail-Resume bleibt bis dahin gesperrt), sichere aktive Testsenken/Testausführung und harte Transportzeitgrenzen ergänzen; Webhook-Dispatcher aus eigenem Paket integrieren. Kein Editor/Skriptumfang in diesem Paket, kein Commit/Push/Deployment.


## P6 Reviewkorrekturen (03.11.2026, feature-engine)

Abgegrenztes Paket zu ADR 0017: Befunde 1/2/3/5/6/8 umgesetzt, Regressionstests geschrieben und alle Swift-Testtargets erfolgreich gebaut (kein Testlauf, DB-Tests laut Nutzer nicht ausführen). Dateiliste, Vertrag, Abnahmefälle und genauer Buildbefehl: `docs/handoffs/P6-Reviewkorrekturen.md`. Worktree `form-backend-engine`, Branch `feature-engine`, ungecommittet; Dateibesitz frei, keine laufenden Jobs.

Nächste Schritte: nach Auftrag mit Docker Flow-DB-/SMTP-Regressionen und unabhängiges Review; danach eigene Pakete für **4 Budgetdurchsetzung** und **7 gemeinsame Sperrreihenfolge Eraser/Checkpoint** (offen, siehe ADR 0017). Vollständiges unveränderliches Mailmanifest bleibt Voraussetzung für Flow-Mail-Resume/Resend. Keine Migration/Veröffentlichung im aktuellen Paket.


## P6 DB-Fehlerkorrektur aus seq2-Lauf (03.11.2026)

Worktree `form-backend-engine`, Branch `feature-engine`, Basis `1fa86bc`; ein schreibender Codex, keine Delegation. Paket: ausschließlich die zwei fehlgeschlagenen FlowIngestTests aus `/tmp/seq2-engine.log`. Log gelesen: Abbruch meldet MySQLError/500 mit unveränderter ready-Outbox; Resend-Test meldet 422 statt 409.

Ursachen und Korrekturen: `FormFlow/FlowStore.swift` schrieb den nicht im Outbox-ENUM enthaltenen Wert `cancelled`, wodurch die gesamte Abbruchtransaktion zurückrollte. Jetzt bestehender Zustand `failed-terminal`, `last_error_code=flow-stopped`, keine nächste Ausführung und Abschlusszeit; weiterhin nur ready-Zeilen des Laufs, ohne Schemaänderung. `FormAdminTests/FlowIngestTests.swift` erwartete ebenfalls den ungültigen Zustand; Assertion auf gültigen Endzustand/Fehlercode/Abschlusszeit angepasst. Der Mailtest übergab eine großgeschriebene Delivery-UUID, obwohl `MailRoutes.lowerUUID` Kleinbuchstaben verlangt; Testeingabe normalisiert, Fehlerantwort in Assertions ergänzt. Die Produktionsvalidierung bleibt unverändert.

Prüfung: `swift build --build-tests` mit den Cache-/Native-Optionen aus `docs/handoffs/P6-Reviewkorrekturen.md` Exit 0; Log `/tmp/seq2-engine-fix-build.log`. `git diff --check` bestanden. Auf Nutzerauftrag keine DB-Tests oder sonstigen Testläufe ausgeführt. Keine Commits, Migrationen oder Veröffentlichungen; vorhandene uncommittete Reviewkorrekturen erhalten. Dateibesitz frei, keine laufenden Jobs.

**Merge offen:** Der angeforderte Merge von main konnte nicht gestartet werden: bereits die Sicherung der lokalen Änderungen mit `git stash push -u` scheiterte am Sandbox-Schreibverbot für `form-backend/.git/worktrees/form-backend-engine/index.lock` (außerhalb des erlaubten Worktrees). Kein Stash erzeugt, kein Mergezustand angelegt. Nächster Schritt: main in schreibberechtigter Umgebung ohne Commit mergen, dabei in STATUS/ARBEITSPLAN beide Seiten behalten und die vorhandenen lokalen Änderungen sichern/erhalten; danach Build wiederholen und die beiden DB-Tests durch den Nutzer ausführen lassen. Der vorliegende Build belegt nur den feature-engine-Stand vor diesem Merge.
## Reviewkorrekturen Domains/Statistik auf main (03.11.2026)

Vier Befunde im Hauptverzeichnis behoben: zeitlich begrenzter Legacy-Einsendungszählpfad mit dauerhafter manueller Löschgrenze, Submit als einzige neue Zählgrundlage, Retention mit mehreren Batches/Arbeitsbudget und 60-s-Folgeausführung, getrennte gültige/ungültige Collectorbudgets für POST/OPTIONS. Abnahmefälle und Dateibesitz: docs/handoffs/Review-Domains-Statistik-Korrekturen.md, Vertrag ADR 0015. Ein schreibender Codex, keine Delegation. Keine Schemaänderung, kein Commit. DB-Lauf wegen unerreichbarem Docker-Daemon offen; nächster Schritt ist P3B_PORT=33420 P3B_NAME=domains-mariadb ./backend/integration-test.sh --filter Domain beim Nutzer. Endgültiger Swift-Prüfstand siehe STATUS.
## P8 Webhooks (03.11.2026, Branch feature-webhooks)
Abgegrenztes Backendpaket: CRUD, verschlüsselte Signierschlüssel, Ingest-Outbox, HTTP-Zustellung/Scheduler und Tests. Dateibesitz: Codex Hauptagent (Package, Ingest, App, FormWebhooks/WebhookDispatcher, Dokumentation); Teilagent API (WebhookRoutes/FormRoutes); Teilagent HTTP (WebhookHTTP/FakeWebhookServer/WebhookHTTPTests); Teilagent Integration (WebhookTests). Keine Schemaänderung, keine PWA, keine Commits/Pushes. Vertrag ADR 0013. Integration läuft ausschließlich mit `P3B_PORT=33418 P3B_NAME=webhooks-mariadb ./backend/integration-test.sh --filter Webhook`; finaler Prüfstand folgt in STATUS/Handoff.

## Webhooks: Astra-Korrekturpaket (03.11.2026)
Ziel/Abnahme: Quoten und terminaler Rückstau, kundenfaire parallele Zustellung ohne Netzwerk unter globalem Lock, begrenzter DNS-Resolver, finale Lease-Prüfung nach Lock-Wartezeit; Vertrag ADR 0013. Dateibesitz ausschließlich Codex-Hauptagent: FormWebhooks, WebhookRoutes, IngestRoutes/IngestConfig, HostGuard, Package, WebhookTests/WebhookHTTPTests/AdminFixture und Dokumentation. Keine Teilagents, keine Schemaänderung, Änderungen auf `feature-webhooks` uncommittet. Implementierung und Kompilierung abgeschlossen, zwei DNS-/Zieltests bestanden; DB-/HTTPS-Abnahme wegen Docker-/Socket-Sandbox offen. Keine laufenden Jobs. Nächster Schritt: Nutzer führt `P3B_PORT=33418 P3B_NAME=webhooks-mariadb ./backend/integration-test.sh --filter Webhook` mit Standardquoten aus; Details und Grenzen in STATUS.
## Fix SDKDeploy-Hänger (03.11.2026)

Paket in `fix-sdkdeploy-hang` / Worktree `form-backend-hang` umgesetzt, nicht committet. Ziel/Vertrag: bestehende Deploy-/Rechte-/Locksemantik erhalten, unbegrenztes FTP-Warten und verschachtelte DB-Poolabhängigkeit beheben; kein Schemawechsel. Dateibesitz und tatsächliche Prüfungen siehe `docs/handoffs/Fix-SDKDeploy-Hang.md`. Abnahme offen: echte FTP-/MariaDB-Regressionsläufe mit einer Poolverbindung und mehrere serielle Gesamtläufe (hier Loopback/Docker gesperrt). Build, vier RemoveTree-Fälle, BlockedTarget, Watchdog und Shellsyntax geprüft. Keine laufenden Jobs, Dateibesitz frei.
## P8 externe Speicher (03.11.2026, feature-storage)

Aktives Paket: ObjectStore DB/S3/SFTP, Inventar-/Uploadzustände, Lese-/Löschpfade, Ingest-Richtlinien, Adminzuordnung/-probe, Tests. Dateibesitz: Hauptagent StorageService, FormAdmin/FormIngest/App, Schema/Package und Doku; delegierte Adapter und Fakes/Adaptertests nach stabilem Protokoll. Worktree `form-backend-storage`, Branch `feature-storage`; keine Commits/Pushes. ADR 0019 beschreibt Vertrag und neue Chiffrat-Spooltabelle. Todolino-Tools sind in dieser Session nicht verfügbar. Prüfungen und Reststand werden im Handoff/STATUS gesichert.

P8-Speicher Abschlussstand: Implementierung und statischer Build vorhanden; 5 socketfreie Tests bestanden, 4 DB-Fälle übersprungen, 2 Socketfälle mit EPERM blockiert. Vorgeschriebener Dockerlauf Exit2. Dateibesitz frei, keine laufenden Jobs, kein Commit/Push. Nächster Schritt: DB-/Transport-/Crash-/Konkurrenzabnahme und Bestandsmigration reviewen; vollständige Übergabe `docs/handoffs/P8-Speicher.md`.

P8-Speicher Nachkorrektur (03.11.2026): Nutzer meldet MariaDB-Gesamtlauf 246 Tests/3 Fehler. Korrekturpaket lokal auf feature-storage: exakte Tabellenzahl 74 (Spool erforderlich), scoped Existenz an Storage-Autorisierung übergeben, 404/403-Regressionen differenziert. Kein funktionierender Bestandsupgrade-Runner vorhanden; DDL-Vorlage allein reicht wegen Baselinechecksummen nicht (ADR 0019 ausdrücklich ergänzt). Dateibesitz für dieses Paket: SplitterTests, StorageRoutes/StorageLifecycleTests, ADR/Status/Plan/Handoff. Nach Prüfung wieder frei; kein Commit/Push.

P8-Speicher Nachkorrektur geprüft: Build erfolgreich, 4 Splittertests bestanden, 4 DB-Recht-/Lifecyclefälle ohne DB übersprungen; Docker weiterhin nicht erreichbar. Dateibesitz frei, keine Jobs, kein Commit. Nächster Schritt: erneuter MariaDB-Lauf und separater versionierter Bestandsupgrade-Pfad (ADR 0019).

## Öffentliche Dokumentation (03.11.2026, abgeschlossen)

Abgegrenztes Paket `site-update`, main-Basis `8444a65`: acht öffentliche Inhaltsseiten plus generierte `site/dist/`-Ausgaben auf vorhandene Funktionen abgeglichen; `status.html` unverändert. Vertrag/Quellen: main-Routen und SDK, Deploy/ENV/BETRIEB sowie ADR 0011/0012/0013/0015/0019; keine Implementierung oder Architekturentscheidung geändert. Abnahme: Build ohne `--base`, Link-/Ankercheck und Diffprüfung bestanden. Ein schreibender Codex; Besitz frei, keine Jobs, kein Commit/Deployment. Grenzen und nächster Schritt: redaktioneller Review, keine erneuten Anwendungsläufe oder visuelle Browserabnahme; offene technische Abnahmen siehe STATUS-Nachtrag „Öffentliche Dokumentation main-Abgleich“.

## P11 — Betrieb: Listener, Einstellungen, Assistent, Migration per PWA, MCP-OAuth (Stand 03.11.2026, geplant)

Entscheidungen des Nutzers: zwei Ports (öffentlich: SDK-Eingang, Statistik-Ereignisse, MCP inkl. OAuth-Endpunkte; intern: PWA und Admin-API, Dashboard optional auch öffentlich, Standard aus). ENV-Einstellungen sollen, soweit unkritisch, auch in der PWA änderbar sein (ENV > DB > Default; Bootstrap-Werte wie DB-Zugang, Serverschlüssel, Ports, vertrauenswürdige Proxys und allowInsecure bleiben ENV). Setup-Assistent für den Erststart. Migration per PWA mit Read-only-Zugang zur Alt-DB (verschlüsselt im SecretStore, Host-Prüfung mit ausdrücklicher Netzfreigabe, Fortschrittsseite, danach abschaltbar). MCP wird von Claude und ChatGPT genutzt und braucht OAuth: Metadaten, Token-Endpunkt und Registrierung öffentlich, die Autorisierung (Login/Consent) leitet auf die interne URL, außer das Dashboard ist öffentlich. Ratelimit pro Token einstellbar.

Reihenfolge: A Listener+Deploy, B Einstellungen, E MCP-OAuth, C Assistent, D Migration-UI. A, D und E sicherheitskritisch (Astra high).

P11-A umgesetzt (03.11.2026) im Worktree `form-backend-listener`, Branch `feature-listener`,
Basis `f5d0d90`, ungecommittet. Vertrag/Abnahme/Dateien: ADR 0020 und `docs/handoffs/P11-A.md`.
Ein Codex, Dateibesitz frei, keine Jobs. Build inkl. Tests, 24 DB-freie Tests, Deploy-Verträge/
Rendering/Shellprüfungen bestanden. Keine DB-Tests oder Docker-Laufzeitabnahme ausgeführt.
Offen vor Übernahme: unabhängiges Sicherheitsreview und Zwei-Port-/Proxy-/DB-Abnahme.
Ingest/Collector/MCP bewusst ausschließlich öffentlich; OAuth nur Erweiterungspunkt.
Danach P11-B und P11-E gemäß Reihenfolge.
## P8 MCP/API-Tokens (03.11.2026)

Paket im Worktree `form-backend-mcp`, Branch `feature-mcp`, ungecommittet umgesetzt; Dateibesitz frei, keine laufenden Jobs. Vertrag/Abgrenzung/Dateien/Abnahme: ADR 0018 und `docs/handoffs/P8-MCP.md`. Persönliche Tokens, selektive REST-Bearer-Auth, MCP-POST-Profil und PWA API-Tokens vorhanden. Keine Schemaänderung, keine OAuth-Implementierung, keine Altcredentials, keine Veröffentlichung oder Entschlüsselung durch Tokens. Build/PWA-Prüfungen bestanden; sieben Swift-DB-Fälle übersprungen, vorgeschriebener Docker-Lauf und Playwright blockiert. Nächster Schritt: `P3B_PORT=33423 P3B_NAME=mcp-mariadb ./backend/integration-test.sh --filter Token` sowie Playwright-Tokenseite nachholen, Sicherheitsreview, echte Zielclientabnahme; OAuth erst eigenes Paket gemäß Handoff.

## P8 MCP – vier Reviewbefunde korrigiert (03.11.2026, feature-mcp)

Im Worktree `form-backend-mcp` ungecommittet: IP-Budgets aus echtem remoteAddress (Proxyheader nur über explizit vertrauenswürdigen Proxy); MCP-Dispatch übernimmt intern geprüfte Identität ohne doppeltes IP-/Tokenbudget, authentifizierte Anfragen ohne Socketadresse nur pro Token; Entwurfsänderungen mit atomarem Token-/Ziel-/Revisions-/Ergebnisaudit und getrennten Fehlerereignissen; Eigenwiderruf nach Eigentumsprüfung/frischer Sitzung auch ohne token.manage. Details/Dateibesitz und Vertrag: ADR 0018, `docs/handoffs/P8-MCP.md`.

Prüfungen: Swift-Build einschließlich aller Tests Exit 0; ausschließlich DB-freie ForwardedForTests ausgeführt (2/2 bestanden); diff --check bestanden. Neue DB-Regressionstests für Budgettrennung/-zählung, Auditrollback und Eigenwiderruf geschrieben/kompiliert, auf ausdrücklichen Auftrag **nicht ausgeführt** (Docker nicht verfügbar). Keine Schemaänderung, kein Commit/Push/Deployment. Dateibesitz frei, keine laufenden Jobs. Nächster Schritt: `P3B_PORT=33423 P3B_NAME=mcp-mariadb ./backend/integration-test.sh --filter Token` in Docker-Umgebung ausführen, danach verbleibende Browser-/Zielclientabnahme und unabhängiges Gesamtreview.

Termin (Nutzerentscheidung 03.11.2026): Ziel Ersatz des Altsystems bis 04.11.2026 abends, spätestens 06.11.2026 8 Uhr. Umstiegsablauf (Nutzer): Koexistenz mit neuer interner und temporärer externer Domain, Setup-Assistent, Alt-DB read-only, Import, Test-Ent-/Verschlüsselung, SDK-Tausch (vor der DNS-Umlegung), Domain umlegen, Testeinsendung. Zusatzpakete: P11-F Umstiegs-Assistent (Key-Import, Formular-Konverter, Delta, Rollback), P7-F SDK-Failover auf Backup-Domain.

## P11-E Übergabe (03.11.2026)

Paket auf `feature-oauth` / `form-backend-oauth`, Basis `4075e49`, uncommittet implementiert.
Ziel/Dateien/Verträge/Abnahme: ADR 0022 und `docs/handoffs/P11-E.md`. Ein schreibender Codex,
keine Teilagents. Schemaentwurf erweitert, bestehende Tokenidentität/PermissionService gemeinsam;
Settings-Registry aus `feature-settings` übernommen und um OAuth-Origins ergänzt (Merge beachten).
Keine DB-Läufe/produktiven Migrationen. Nächster Schritt: unabhängiges Sicherheitsreview,
Docker-DB-Abnahme mit `--filter OAuthIntegrationTests`, Browser-/Claude-/ChatGPT-Abnahme und
versionierter Bestandsupgradepfad. Prüfstand in STATUS; Dateibesitz bei Übergabe frei, keine Jobs.
## P11-B — Systemeinstellungen (03.11.2026)

Ziel/Vertrag: ADR 0021, Todolino E5C65FC4-4409-49F3-A4D0-3E25E231BF7C.
Ein schreibender Codex auf `feature-settings`, Worktree `form-backend-settings`;
Dateibesitz: Registry/FormCore, SystemSettings/FormPersistence, SettingsRoutes und
Verdrahtung FormAdmin/App/Ingest/WebhookLimits, Rechtekatalog/DDL, PWA-Seite/Tests,
ADR/Status/Handoff. Keine Delegation, kein Commit oder Deployment. Testumfang:
Swift-Build inkl. Tests, DB-freie Settings-/Rechtetests, PWA Vitest/Playwright;
DB-Tests auf Nutzeranweisung nicht ausführen. Prüfstand und nächste Schritte:
`docs/handoffs/P11-B.md`.

## P7-F SDK-Failover – Übergabe (03.11.2026)

Todolino D2EC6C64-AB8C-4234-A7CC-C94E80C1F89E, Worktree `form-backend-failover`, Branch `feature-failover`. Paket implementiert, ungecommittet: signierte geordnete SDK-Endpunkte, restriktive Fehlerklassen, Zeit-/Versuchsbudget, bytegleiche Wiederholungen; Backup über vorhandene API-Hostverwaltung ohne Migration. Dateibesitz ausschließlich Codex (SDK, KeyRoutes, DomainIngestStatisticsTests, ADR 0020/Signaturvertrag/Status/Plan/Handoff), bei Übergabe frei; keine laufenden Jobs oder Delegation. Abnahme/Vertrag und Dateiliste: `docs/handoffs/P7-F.md`. PHP 120+47 Prüfungen, Swift-Testbuild und 14 DB-freie Swift-Fälle sowie PHP/Swift-Interop bestanden. DB-Tests auf Nutzerauftrag nicht ausgeführt. Nächster Schritt: Domain-Integration mit Docker (Befehl im Handoff), unabhängiger Review und echte TLS-/Proxy-Failoverabnahme. Kein Commit/Push/Deployment.


## P9 Retry-Nachkorrektur (03.11.2026)

Abgegrenzter Fix auf `feature-migration` / Worktree `form-backend-migration`: falsches Feld-Review durch JSON-Schlüsselsortierung beheben; bedingungslosen Status-/Abschluss-UPDATE und Issue-Sperre aus ADR 0014 erhalten. Dateibesitz ein Codex: Transform.swift, MigrationTests.swift, ADR 0014, STATUS/ARBEITSPLAN und P9-Handoff. Inhaltsvergleich implementiert, Erstlauf-Voraussetzungen im Retry-Test ergänzt. Kein Commit, keine Delegation, keine produktive Migration. Abnahme: `swift build --build-tests` mit nötigen lokalen Cache-/Sandboxoptionen; DB-Regressionslauf mangels Docker offen. Nächster Schritt: Nutzer wiederholt Migration-Integrationstest mit Port 33419 / Container migration-mariadb; Prüfstand im P9-Handoff.

P9 Retry-Prüfabschluss: `swift build --build-tests` mit lokalen Caches, `--disable-sandbox --build-system native` und `TMPDIR=/private/tmp` erfolgreich (Exit 0, Tests kompiliert/verlinkt). Isolierter Inhaltsvergleich geprüft; `git diff --check` erfolgreich. Keine DB-Tests ausgeführt. Dateibesitz frei, keine laufenden Jobs, nichts committet. Nächster Schritt bleibt der Migration-DB-Lauf beim Nutzer; exakter Buildbefehl/Grenzen im P9-Handoff.


## P6 seq3-Ingest/Webhooks nach main-Merge (03.11.2026)

Paket auf `feature-engine` im Worktree `form-backend-engine` abgeschlossen, ungecommittet; ein schreibender Codex, keine Delegation. Alle sieben Assertions aus `/tmp/seq3-engine.log` einzeln geprüft: sechs Folgefehler durch doppelte Standard-/Flow-Outboxeinreihung, eine falsche Text-Erwartung beim bereits korrekten Mail-409. `IngestRoutes.swift` reiht Standard-Webhooks jetzt ausschließlich beim Standardplatzhalter ein; eigene Flows steuern sämtliche Zustellungen selbst, auch ohne Webhook-Baustein. Regel/Begründung in ADR 0017. `FlowIngestTests.swift`: Mailassertion auf öffentlichen Fehlervertrag korrigiert; zusätzliche Regression zu Placeholder/Flow-ohne-Webhook, inaktiven Endpoints und Replay. Keine Aufweichung der bisherigen Queue-/Abbruchassertions.

Prüfung: `swift build --build-tests` mit lokalen Caches und nativem Builder Exit 0 (17,28 s), Log `/tmp/seq3-engine-fix-build.log`; `git diff --check` bestanden. Auf ausdrücklichen Auftrag keine Tests/DB-Läufe. Keine Schemaänderung, Commits, Migrationen oder Deployments; keine laufenden Jobs, Dateibesitz frei. Einzelbefunde, Dateibesitz, Grenzen und nächster Befehl: `docs/handoffs/P6-Seq3-Ingest-Webhooks.md`. Nächster Schritt durch Nutzer: DB-Lauf `P3B_PORT=33422 P3B_NAME=engine-mariadb ./backend/integration-test.sh --filter Flow`. Bestehende Lücken (Budgets, Sperrreihenfolge, Flow-Rückstaugrenze) bleiben offen. Der frühere Hinweis „Merge offen“ ist durch den vom Nutzer bestätigten main-Merge überholt.

## P12 — Oberfläche (Nutzerwunsch 03.11.2026)

- P12-A: PWA-Oberfläche im Stil von `timetrack-pwa` (Design-Tokens in OKLCH, shadcn-svelte, Sidebar/TopBar-Shell, Theme/Akzent, Hilfe). Erst Fundament und Shell mit Login/Setup/Überblick, danach alle Seiten.
- P12-B: Schlüsselverwaltung für Nutzer unsichtbar. Keyring entsperrt sich nach Passkey-Login automatisch (PRF), Kundenschlüssel entstehen beim Anlegen automatisch, Rotation/Rewrap/Hold-Umhängen laufen im Hintergrund, manuelle Schlüsseleingabe entfällt. Sichtbar bleibt nur der einmalige Wiederherstellungscode im Setup und ein Hinweis, wenn ein Gerät kein PRF kann. Der Server bleibt zero-knowledge: Schlüsselarbeit geschieht nur in einer entsperrten Browsersitzung.
## Feature-Inventur und Abnahmegerüst Altbestand (03.11.2026)

Paket `parity-inventory` dokumentarisch geliefert: `docs/paritaet/featureliste-alt.md` (151 FA-IDs: 53 vorhanden / 62 teilweise / 33 fehlt / 3 bewusst entfallen) und `docs/paritaet/abnahme-skript.md` (ausführbarer Pythonblock, sichere HTTP-Grundchecks, Ergebnis je ID, manuelle Durchläufe und Regressionsbefehle). Vertrag: erneute lesende Altcode-Inventur plus Gegenstücksuche ausschließlich im aktuellen Checkout; keine Implementierung/Architekturentscheidung, Secrets oder Altänderung. Dateibesitz ein Codex für diese zwei Dateien und STATUS/ARBEITSPLAN; bei Übergabe frei. Branch `parity-inventory`, Worktree `form-backend-parity`, Basis `2374ea0`.

Abnahme der Dokumentstruktur/Belegpfade/Zeilenbereiche/Zählung und Syntax/Init/Ergebnisführung des Gerüsts erfolgt; keine Laufzeitabnahme behauptet. Fünf blockierende macOS-Platzhalter bleiben als Lektüregrenze ausdrücklich aufgeführt (Details im Inventar/STATUS); keine produktiven Jobs gestartet, Leseversuche beendet, kein Commit. Nächster Schritt: Erstquellen vervollständigen, Muss-Fehlstellen und Muss-Teilfunktionen priorisiert bearbeiten, danach jede FA-ID am isolierten Ersatzbackend tatsächlich prüfen. TOTP darf ohne neue Entscheidung nicht als bewusst entfallen gelten.

## P11-G — Übergabe 03.11.2026

Ziel/Vertrag: Nutzerentscheidung Passkey-only intern, Zweitfaktor öffentlich;
ADR 0022 und `docs/handoffs/P11-G.md`. Paket lokal implementiert, DB-/Browser-/
unabhängige Sicherheitsabnahme offen. Ein Codex auf `feature-auth` im Worktree
`form-backend-auth`, Dateibesitz Backend Auth/Konten/Config/App + PWA Konto/Setup/
Logintests + Deploy-ENV + Auth-Verträge/ADR/Status/Handoff; bei Übergabe frei.
Keine Jobs oder Commits. Abnahmeumfang: Testbuild, DB-freie Policy/UV-Tests,
PWA Check/Lint/Vitest/Build bestanden; DB-Regressionen nur kompiliert (Nutzerauftrag),
Playwright EPERM, Vertragsvalidator Katalogabgleich offen. Konkreter nächster
Docker-/Browserbefehl und sämtliche Grenzen im Handoff; kein Deployment.

## P12-B — geprüfter Teilstand, Fortsetzung offen (03.11.2026)

Ziel bleibt vollständig unsichtbare Schlüsselarbeit bei unverändertem Browservertrauen. Branch `feature-keys`, Worktree `form-backend-keys`; ein Codex, Dateibesitz wieder frei, keine Jobs/Commits. Dateivertrag: Browserkrypto/Login/Session, betroffene Verwaltungsseiten und Tests/Dokumentation; keine Änderungen am feature-ui-Fundament oder Backend. ADR 0024/Handoff `docs/handoffs/P12-B.md` beschreiben Ergebnis, Abnahme und offene Grenzen.

Vorhanden: Login-PRF, automatische Kundeneinrichtung, Rewrap-Warteschlange für bestehende Rotationen, Keyring statt Rohschlüsseleingabe, technische Panels unter Konto/Erweitert. Nachgewiesen: check/lint/83 Vitest/Build/diff --check. Playwright durch Loopback-EPERM vor Start blockiert; keine DB-Tests.

Paket **nicht erledigt**: zuerst Kontorecovery mit versioniertem Bestandsupgrade/API, einmaligem Setupcode und Nicht-PRF-Login implementieren; anschließend dauerhaften Rotationsbedarf/automatischen Beginn, sichere Zugangsreparatur und Hold-Auftragswarteschlange ergänzen. Kundengebundene Codes und manuelle Aktionen in Erweitert sind ein Zwischenstand. Echte PRF-/Fallback-Browserfälle und unabhängiger Sicherheitsreview fehlen. Keine erneute Produktfreigabe erforderlich: diese Arbeiten sind vom Nutzerauftrag bereits umfasst.

## P12-A Schritt 1 – Übergabe 03.11.2026

Implementiert auf `feature-ui` / `form-backend-ui`, ungecommittet. Ziel/Vertrag:
ADR 0022, vollständige Dateien/Prüfungen/Grenzen: `docs/handoffs/P12-A.md`.
Ein Codex, Dateibesitz wieder frei, keine Jobs. UI-Fundament, responsive Shell,
Login/Passkey-Setup und Überblick fertig; P12-B-Dateien unberührt.
Check/Lint/81 Vitest/Build bestanden. Browserabnahme ist ausdrücklich offen:
`npx playwright test` scheitert am gesperrten Preview-Listener (`EPERM ::1:4173`).
Nächster Schritt: alle 45 Playwright-Fälle inklusive axe ausführen und visuell
Desktop/Mobil prüfen; anschließend Schritt 2 (übrige Seiten) beauftragen.


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

Umfangsentscheidung (Nutzer, 03.11.2026): Alle Funktionen der Feature-Inventur werden genutzt (Turnstile/Captcha, TOTP, Google-Ads-Auswertung, MCP-Statistik) mit einer Ausnahme: Der Docker-Kundenagent (FA-119) entfällt, kein Kunde braucht ihn. Folge: Ads-Auswertung (FA-080/081/122) braucht im Neubau eine Erfassung der Ads-Merkmale (z. B. GCLID) in den Statistikereignissen; das ist ein eigenes Paket (P13-Ads).
## Auditfix Session/Keyring und DCR (03.11.2026)

Paket auf `fix-audit` / `form-backend-auditfix` implementiert, ungecommittet.
Ein Codex; Dateivertrag/Abnahme/Quellenabweichung und nächste Befehle im Nachtrag
`docs/handoffs/P11-E.md`, Entscheidung ADR `0022-mcp-oauth.md`.
Ziel: Nullung bei Konto-/Sitzungswechsel mit Tab-Invalidierung; DCR 200/Stunde
global, maximal 1000 ohne Grant, 24-h-Ablauf und wertfreies Audit. Keine Migration.
DB-Tests nur kompilieren. Nach Prüfabschluss Dateibesitz frei, keine Jobs;
Fortsetzung: Docker-OAuth-Tests und Browser-Zweittabfall/Sicherheitsreview.

Auditfix-Abnahme lokal abgeschlossen: 107 Vitest, 4 DB-freie Registrytests,
Swift-Testbuild, PWA Check/Lint/Format/Build und Diffprüfung bestanden.
Dateibesitz frei, keine Jobs/Commits. Offen bleiben Docker- und Zweittab-Browserabnahme.
## Export/Auskunft — Übergabe 03.11.2026

Paket FA-061/068/073–075 auf `feature-export`, Worktree `form-backend-export`.
Ein schreibender Codex ohne Delegation; Besitz: neue `pwa/src/lib/export/*`,
`routes/admin/Export*`/`Suche*`, kleine EntriesTab-Einbindung, eigene i18n-Schlüssel,
PrivacyRoutes/-Tests und Paketdokumentation. Vertrag: ADR 0012/0024, lokale
Entschlüsselung und Personensuche, CSV-/JSON-Auswahl, explizite Fehler-Marker,
live PermissionService, wertfreier Audit vor Download. Kein neues Schema oder
konfigurierbarer Wert erforderlich (ADR 0021 bleibt unverändert). Abnahme:
Swift-Testbuild und DB-freie Unit-Tests, PWA check/lint/vitest; DB-Tests nur schreiben
und kompilieren, kein Docker/Playwright, kein Commit. Abgeschlossen: Swift-Testbuild, 28 DB-freie Swift-Tests,
PWA check/lint/118 Vitest-Tests und diff --check bestanden. DB-Tests geschrieben
und kompiliert, nicht ausgeführt. Dateibesitz frei, keine laufenden Jobs.
ADR 0026 und `docs/handoffs/Export-Auskunft.md` enthalten Dateien, Vertrag,
Prüfungen und Grenzen. Nächster Schritt: externe DB-/Browserabnahme und Review.
## Betrieb — Paketvertrag (03.11.2026)

Ziel: FA-085/086/089/063 mit autorisierter Aufbewahrung (FA-134/135).
Dateibesitz ein Codex auf `feature-ops` / `form-backend-ops`: Ops-Neudateien Backend/PWA
und Tests, notwendiger Register-/Routing-/Navigationsanschluss, eigene i18n-Schlüssel,
SettingsRegistry, Baseline/Upgrade 0026/Splitterzählung und Paketdokumentation.
Vertrag/Abnahme: ADR 0026 und `docs/handoffs/Betrieb.md`. Tests: Swift-Testbuild,
DB-freie Units, PWA check/lint/vitest; DB-Integration schreiben, nicht ausführen.
Keine Delegation, Commits, produktiven Migrationen oder Veröffentlichungen.
Nächster Schritt nach lokalen Prüfungen: unabhängiges Review, isolierte DB-/SMTP-Abnahme.

Betrieb — Übergabe: Implementierung lokal fertig, Dateibesitz frei, keine Jobs.
Testbuild + 10 reine Swift-Tests + PWA check/lint/107 Vitest erfolgreich.
DB-Tests nur kompiliert; Abnahme von Triggern/Upgrade/Nebenläufigkeit/SMTP und Browser
weiter offen. Befehle und Fortsetzungsvertrag: `docs/handoffs/Betrieb.md`.
Kein Commit, Deployment oder produktiver Lauf.
Betrieb-Nachprüfung: Quittierung pro Ereignis und festgehaltene Mailzielkennung
integriert, Testbuild/10 DB-freie Tests erneut grün. Weiter mit dem DB-/SMTP-Review
laut Betrieb-Handoff; keine laufenden Jobs.
## Paket Konten (03.11.2026)

Ziel/Vertrag/Abnahme: FA-091/092/093/145/098/100/102/103, ADR 0026, `docs/handoffs/Konten.md`. Ein schreibender Codex auf `feature-accounts` / `form-backend-accounts`, Dateibesitz FormAuth, ergänzende AccountRoutes, PWA Account/Members sowie notwendige Login-/API-Integration, Tests/DDL 0026/i18n/Dokumentation. Keine Delegation oder Commits. Swift-Testbuild, DB-freie Unit-Tests, PWA check/lint/vitest; DB-Tests nur kompilieren, Docker/Playwright auf Nutzerauftrag nicht ausführen. Nächster Schritt nach lokalem Prüfabschluss: DB-/Browserabnahme und unabhängiger Sicherheitsreview; exakter Befehl im Handoff.

Konten-Prüfabschluss: Implementierung lokal geliefert; Swift-Testbuild, 18 DB-freie Tests, PWA check/lint/105 Vitest und diff --check bestanden. Keine laufenden Jobs, Dateibesitz frei, kein Commit. DB-/Browserlauf und unabhängiger Sicherheitsreview offen; nächster konkreter Befehl/Grenzen in `docs/handoffs/Konten.md`.
## Paket Missbrauchsschutz (03.11.2026)

Ziel/Abnahme: FA-012/013/014 Turnstile, FA-016/017 Sperren/Listen, FA-033/034
Hashprüfung, FA-044 Empfängerschranke. Vertrag ADR 0026; Dateibesitz/Tests und
konkrete Fortsetzung `docs/handoffs/Missbrauchsschutz.md`. Ein schreibender Codex
auf `feature-abuse` im Worktree `form-backend-abuse`, keine Delegation/Commits.
DB- und Browserabnahme beim Nutzer offen; keine produktive Migration ausführen.

Prüfabschluss Missbrauchsschutz: Testbuild/46 Swift-Unit-/105 Vitest-Fälle und
PWA-Check/Lint/diff --check bestanden; keine DB-Tests, keine laufenden Jobs,
Dateibesitz frei. Nächste Schritte und Validator-/DDL-Grenzen im Handoff.
## P11-C/D – internes Setup und Migrationsjobs (03.11.2026)

In Bearbeitung auf `feature-assist`, Hauptcheckout `form-backend-assist`; ein Codex,
keine Delegation/Commits. Dateibesitz Backend-/PWA-Setup/Migration, Importercheckpoints,
Katalog/DDL/Upgrade, Tests und ADR 0026/Handoff P11-CD. Abnahme: Swift-Testbuild,
DB-freie Regeln, PWA check/lint/Vitest/Build; MariaDB-Tests nur schreiben/kompilieren,
Playwright nur schreiben. Zielvertrag ADR 0026, UX 3.17/5, P9/P11-B/P11-F.
Blockierende Bestandslücke: P12-B-Kontorecovery fehlt. Keine Abschlussbehauptung für
Assistent, synthetische Datenprüfung, Cutover oder produktive Migration.

P11-CD Übergabe: Backendjobs/Quellprüfung/Plan/Inventar/Mehrkundenzuordnung/
Worker-Konverterphase und PWA-Fortschritt implementiert. Swift-Testbuild und zwei
DB-freie Tests, PWA check/lint/112 Vitest/Build erfolgreich; keine DB-/Playwright-Läufe.
Dateibesitz frei, keine Jobs/Commits. **Gesamtpaket offen:** kontoweite P12-B-Recovery
fehlt, Setup blockiert Schritt 2; Schritte 3–6 als geführter Abschluss mit realer
Datenprobe noch ergänzen. Verbindlicher nächster Einstieg: `docs/handoffs/P11-CD.md`.
## MCP-Werkzeuge – FA-122/123/124 (03.11.2026)

Aktiv auf `feature-mcpstat` / `form-backend-mcpstat`, ein Codex ohne Delegation.
Ziel, Dateibesitz, Vertrag und Abnahme: ADR 0026 und `handoffs/MCP-Werkzeuge.md`.
Werkzeuge/Tests vorbereitet; noch Freigabe der Nicht-OAuth-Dateien TokenService.swift
für expliziten Statistikscope und StatisticsRoutes.swift für gemeinsamen Reader erforderlich.
Bis dahin keine bestehende Tokenfreigabe erweitern. DB-/Playwright-Prüfungen auf
Nutzerauftrag ausgespart. Prüfresultate und laufende Prozesse bei Übergabe ergänzen.

## P13-Ads – Abschluss des Implementierungspakets (03.11.2026)

Ziel/Vertrag/Abnahme und Dateibesitz: ADR 0032, `docs/handoffs/P13-Ads.md`.
Branch `feature-ads`, Worktree `form-backend-ads`, ein Codex ohne Delegation.
Implementiert: minimaler Ads-Indikator, aggregierte REST-/MCP-Ausgabe mit
Kleingruppenschutz und PWA; Upgrade 0031/Schema/Splitter. Keine Kampagnenannahme
aus Klickkennung. Dateibesitz frei, keine Jobs oder Commits. Swift-Testbuild,
10 reine Swift-Tests und PWA Check/Lint/136 Vitest bestanden. DB-Tests nur
kompiliert. Fortsetzung: unabhängiger Review und DB-/Browserabnahme gemäß Handoff;
Hostansichten müssen den optionalen Indikator liefern, Altbestand bleibt unbekannt.
## Auditpaket 8B72B9D6 — 03.11.2026

Begrenztes Paket auf `audit-run` / `form-backend-audit` (Basis `298b6c0`), ein Codex,
keine Delegation/Commits. Vertrag/Dateibesitz/Abnahme:
`docs/handoffs/Audit-8B72B9D6.md`. Konverter nur intern; strikte Migrationsnetze mit
DNS-Pinning; TOTP-Trim; Race-Dokumentation ADR 0027. Abgeschlossen: Swift-Testbuild (nativer Builder), sechs
DB-freie Regressionstests und Diffprüfung erfolgreich. Dateibesitz frei, keine Jobs;
DB-Tests nur kompiliert.
Nächste externe Abnahme: MariaDB-Tests, Passwortwechsel-Race bleibt offenes Folgepaket.

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
## P11-F Rest — Übergabe 03.11.2026

Paket 8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D, `feature-keyimport` /
`form-backend-keyimp`: lokale :2-HPKE-Entschlüsselungsprobe mit flüchtiger Eingabe,
Chiffrat-Hashbestätigung und lokaler frischer Testverschlüsselung; additive neue
Snapshots mit Quell-ID-Ledgerprüfung, Abbruch-/Rollback-/Abschalthinweis umgesetzt.
Dateivertrag/Abnahme ADR 0033 und `handoffs/P11-F-Rest.md`; Upgrade 0032 ungeprüfter
Bestandskandidat. Swift-Testbestand kompiliert, PWA Check/Lint und 159 Vitest grün;
DB-/Browserlauf, Upgradeabnahme und unabhängiger Review bleiben beim Nutzer.
Ein schreibender Codex, keine Delegation/Commits, Besitz frei, keine Anwendungsjobs.
Keine Cutoverfreigabe; RSA/CBC und finaler Löschabgleich bleiben außerhalb des Pakets.
