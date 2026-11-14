# Tatsächlicher Stand

## Migration: Altanfrage ohne formularUUID (14.11.2026, Todolino 4E46E368, Branch `worktree-agent-a05104ab9c7aeb0e3`, lokal committet, nicht gepusht)

- Ursache: `anfragen.formularUUID` ist im Altschema nullable; `owner()` warf `invalidSourceAt(missingValue)`, der Lauf brach ab. Änderung: Zeile wird übersprungen, Prüffall `orphan-row` (offen), `TableParity.orphanCount` im Bericht (Fallback-Formular verworfen: kein Kunde/Schlüssel zuordenbar; Daten bleiben im Quelldump).
- Test: `testSubmissionWithoutFormIsReportedAsOrphanAndDoesNotAbortTheRun` (Probelauf, echter Lauf, Wiederholung); Mutationsprobe ohne Fix rot (`invalidSource ... column=formularUUID`). `FormMigrationTests` mit DB: 44 grün.
- Grenzen: nur `anfragen` (die anderen Tabellen haben `formularUUID NOT NULL`); andere fehlende Pflichtspalten brechen weiter ab; der Lauf endet wegen des offenen Prüffalls als `failed`, bis der Fall bewusst angenommen wird.
## Client-IP für Missbrauchssperre und Ingest-Budget (14.11.2026, Todolino 1BEEDE0F, Worktree-Branch `worktree-agent-a8b313f2a27af0a35`, lokal, nicht gepusht)

- Befund (belegt): `main.swift` verdrahtete den `ClientIPResolver` für den Ingest bereits (vertrauter Peer, X-Forwarded-For von rechts). Lücken: Ban-Digest und Budget nutzten die volle IPv6-Adresse statt /64 (Rotation innerhalb eines /64 umging Sperre und Budget); die Auflösung stand als Inline-Closure ohne Test.
- Fix: `IngestConfig.proxiedClientIP(trusted:)` (alle XFF-Zeilen, Auflösung nur bei vertrautem Peer) und `clientKey` (= `IPAddr.quotaKey`) für `AbuseProtection` (Ban-Digest) und `enforceBudget`. Roh-IP bleibt für `abuse.blockedNets`. Übrige `remoteAddress`-Stellen geprüft: Dashboard-Host/Statistik/Listener nutzen den Peer bewusst für die Vertrauensprüfung, Auth-Pfade nutzen schon den Resolver.
- Tests (`IngestDBTests`, 20/20 grün, DB-Integration): zwei Clients hinter vertrautem Proxy getrennt gezählt (Ban und Budget), Spoof-Header von unvertrautem Peer ignoriert, linker XFF-Eintrag ignoriert, IPv6 /64 geteilt. Mutationsproben: (1) `clientKey` ohne /64 -> 2 Tests rot; (2) Vertrauen ignoriert (Resolver mit 0.0.0.0/0) -> Spoof-Assertions in 2 Tests rot.
- Grenze: Das PHP-SDK sendet keine Besucher-IP; ruft ein Kundenserver das Backend auf, bleibt dessen Adresse der Client. Das eigentliche Kartenproblem (Bot sperrt Website) braucht die signierte Besucherkennung im SDK (offen). BETRIEB.md warnt, bis dahin Turnstile/Sperrlisten nicht zu aktivieren.

## S2-03 Nachbesserung nach Codex-Review (14.11.2026, Karten S2-03a 12CEEEFE, S2-03b 46B784C4, S2-03c 88B3E7CC; Branch wie unten, lokal, nicht gepusht)

- (a) Compiler-DoS: festes Arbeitsbudget (50 000 Besuche) + leere quantifizierte Gruppen werden beim Parsen verworfen. (b) Klassenoperatoren `&&`, `--`, `||`, verschachtelte/POSIX-Klassen, `[]` abgelehnt. (c) `\w`/`\d`/`\s` wie ICU; Differentialtest gegen ICU über U+0000..U+1FFFF (Private Use ausgenommen: Apple-ICU-Daten weichen dort ab, `\s` enthält U+000B/U+0085, gemessen).
- Mutationsprobe (alte `LinearRegex.swift` aus 8eb0c95): `testCompilerWorkIsBounded` rot (3x Watchdog 5 s, Test selbst beendet nach 15 s), `testClassSetOperatorsAreRejected` rot, `testClassMembershipMatchesICU` rot, `testDifferentialAgainstICU` rot; mit Fix alle grün.
- Migration: Inventur: der Konverter (`LegacyFormConverter`) importiert keine Alt-Regulärausdrücke (`regel` -> "nicht abbildbar"), erzeugt nur `^-?[0-9]+([.,][0-9]+)?$` (im Dialekt); Muster können also nur aus dem Editor/der API stammen. Neu: `FormIngest/PatternCompatibility` + `App migrate` gibt `WARNING pattern-incompatible: form=… field=…` für aktuelle Releases aus (read-only). Doku: BETRIEB.md, UMSTIEG-CHECKLISTE.md (6b), MIGRATION-ANLEITUNG.md. Einsendungen werden weiter abgelehnt (nicht still): Meldung ist vorgelagert.
- Grenzen: Prüfung betrifft nur aktuelle Releases (nicht Entwürfe/alte Versionen); Differentialtest nur bis Plane 1.

## Regex-ReDoS in der Formularvalidierung behoben (14.11.2026, Todolino S2-03 017C4F98, Worktree-Branch `worktree-agent-a4abe8cc3317dc34e`, lokal committet, nicht gepusht)

- Ursache (belegt): Der Textfilter `hasNestedQuantifier` ließ `((a|aa))+` durch (innere Klammer beendet `[^)]*`); `NSRegularExpression` hat kein Zeitlimit und ist nicht abbrechbar. Mutationsprobe: mit dem alten Matcher hängt `SubmissionValidationTests/testReviewFindings` (Muster `((a|aa))+`, `"a"*100+"!"`) über 180 s (Prozess abgebrochen).
- Änderung: `FormCore/LinearRegex.swift` (NFA-Simulation, linear, eingeschränkter Dialekt, siehe ADR 0046). `SubmissionValidation` nutzt sie; `DocumentValidator` lehnt Muster außerhalb des Dialekts beim Speichern ab (`/form/fields/<id>/validation/pattern`). Längenlimits bleiben (Muster 500, Eingabe 2000 Byte).
- Tests: neu `LinearRegexTests` (3; legitime Muster, Ablehnung, Wächter 5 s gegen Hängen), Ergänzung `SubmissionValidationTests`, `ReleaseFlowTests.testDocumentValidatorRejectsPatternsOutsideTheLinearDialect`. Bestandstests grün (macOS und `ci-linux.sh`).
- Grenzen: Semantik leicht anders als ICU (siehe ADR); Altformulare mit Mustern außerhalb des Dialekts lehnen Einsendungen ab. Andere `.regularExpression`-Aufrufe nutzen feste eigene Muster (nicht betreiberdefiniert).

## OAuth-Registrierung gehärtet (14.11.2026, Todolino C3104C0F, Worktree-Branch `worktree-agent-aef4e373e3f1e62d0`, lokal committet, nicht gepusht)

- Ursache (belegt, Repro `fb-sec/scripts/t_oauthreg.py`): `POST /oauth/register` (öffentlich) erlaubte pro IP 5 pro Minute = 300 pro Stunde, mehr als der globale Deckel `oauth.registrationsPerHour` (200). Eine Adresse konnte den globalen Deckel ausschöpfen, andere Adressen bekamen dann 429. Ungenutzte Clients lebten 24 h, IPv6-Adressen wurden einzeln gezählt (2^64 Schlüssel pro Anschluss).
- Änderung: (1) Quota pro Adresse 10 pro Stunde (`OAuthService.registrationsPerIPPerHour`, Fenster 3600 s). (2) `OAuthService.unusedClientTTL` = 1 h statt 24 h, gilt für Bereinigung (`AuthMaintenance.purgeExpired`) und für Autorisierung/Consent; nur Clients ohne jeden Grant. (3) `IPAddr.quotaKey`: native IPv6 auf /64 normalisiert, IPv4 und IPv4-mapped unverändert. Feste Konstanten statt neuer Einstellungen, daher keine ENV-/BETRIEB-Änderung; Nachtrag in ADR 0022.
- Tests: `OAuthIntegrationTests.testOneAddressCannotExhaustGlobalCapAndIPv6UsesSlash64` (neu), `testRegistrationIsPendingAndRateLimited` (10 statt 5), `testUnusedExpiryKeepsConsentedClientsAndAuditsOnlyCount` (Grenze 3600 s); `ClientIPTests.testQuotaKeyReducesIPv6ToSlash64`. Alle grün (`integration-test.sh --filter OAuthIntegrationTests`: 12/12). Mutationsproben rot: altes Limit 5/min (14 Fehlschläge), TTL 86400 (4), ohne /64 (1).
- Grenze: Hinter NAT/CGNAT teilen sich Nutzer die 10 pro Stunde; Werte nicht per Einstellung änderbar. Der globale Deckel bleibt ein gemeinsamer Engpass (20 Adressen pro Stunde reichen weiterhin; kein Schutz gegen verteilte Angriffe).

## Flake Mail-Tests: Ursache belegt und behoben; check-deploy.py repariert (14.11.2026, Worktree-Branch `worktree-agent-a25dfc28f35a8cfa3`, lokal committet, nicht gepusht; Todolino EB6ED178, EC5C9C9A)

- Ursache Flake (belegt): `MailDispatcher.renewLease` leitete "Lease noch unser" aus `ROW_COUNT()` ab. MariaDB meldet nur geänderte Zeilen, und `DB.time` hat Millisekunden-Auflösung (DateFormatter, `.316000`). Zwei Verlängerungen (vor Warteschlange und vor dem Senden) in derselben Millisekunde schreiben identische Werte, 0 Zeilen, `false`: `deliver` kehrte still zurück (kein Log, Zeile bleibt `leased`, keine Mail). Betrifft die Tests nur, wenn beide Aufrufe in dieselbe Millisekunde fallen, also bei schneller Maschine oder wenn die DB-Antwort langsam ist, die Zeitstempel aber vorher gebildet wurden. Last erhöht die Trefferquote (DB auf 0,15 CPU gedrosselt: 2 von 3 Läufen scheiterten; 12 reine CPU-Hogs: nicht reproduzierbar). Die 8-s-/30-s-Verlängerung (fc13427) war daher wirkungslos; die Wartebedingung hatte nie ein Zeitproblem.
- Fix: `renewLease` liest den Besitz per `SELECT COUNT(*)` (Zeile, Token, Zustand `leased`) statt ROW_COUNT. Regressionstest `MailEndToEndTests.testLeaseRenewalWithIdenticalTimestampStillCountsAsOwned` (eingefrorene Uhr, deterministisch; Mutationsprobe: mit altem Code rot, mit Fix grün; fremdes Token bleibt abgelehnt). Andere ROW_COUNT-Stellen geprüft: setzen neues Token/Zustand, daher unbetroffen.
- check-deploy.py (EC5C9C9A): Test veraltet, keine Umgebungsabweichung. Seit 260a255 veröffentlicht `stack.env.example` beide Listener im Modus ingress, `lib.sh` setzt dann `endpoint_mode: vip` (stack.yaml-Default dnsrr unverändert gültig). Test setzt Publish-Ports in den Render-Fällen nun explizit leer. `python3 scripts/check-deploy.py` Exit 0 (ca. 3 min). Kein CI-Schritt aufgenommen (Laufzeit, Pty-Menütests auf dem Runner unerprobt).
- Offen: `DB.time` bleibt auf Millisekunden (global, nicht angefasst). Reproduktion: `DOCKER=<Wrapper mit --cpus 0.15 für mariadb> ./backend/ci-linux.sh --filter 'MailEndToEndTests|FlowIngestTests'`.

## Vendor-Review 2: Auth-Fehler redigiert, Handshake-Tests belastbar, echter Watchdog (14.11.2026, Worktree-Branch `worktree-agent-a2a1b53f5ced7ea43`, lokal committet, nicht gepusht; Todolino B42C8C7E, 83B4BA8C, 8E75A8E5)

- Quelle: Codex-Review `orchestrator/runtime/fb-sec-codex-vendor2.md`. (1) Auth-/Early-ERR-Pakete gingen unredigiert als `MySQLError.server` an den AsyncKit-Pool, der `String(reflecting: error)` auf `error` loggt (DB-Benutzer, Host, Servertext). Fix `LOCAL PATCH` in mysql-nio: `ERR_Packet.redactedForConnect()` (nur errno und bereinigter SQLSTATE; Text "server message redacted") an den drei Connect-Stellen in `MySQLConnectionHandler` (Early-ERR, caching_sha2, native); Fehlerklasse `.server` und errno bleiben, `SourceFailure.classify` (1045/1049/1044) unverändert. Query-Fehler (Duplicate, Syntax, Importer) unberührt.
- (2) Handshake-Tests: Timeout 30 s bei erlaubter Latenz 5 s (nur der `channelInactive`-Patch erklärt das schnelle Scheitern); neu: Close während der Authentifizierung, TLS-Stall (SSLRequest/ClientHello werden verschluckt, nur Timeout beendet); je danach derselbe Poolplatz (1 Verbindung/Loop) wiederverwendet. (3) `withDeadline` ersetzt durch echten Watchdog (Fortsetzung nach Ablauf, auch wenn die Operation hängt; bei Ablauf schließt der Proxy alle Sockets; `asyncShutdown` ebenfalls begrenzt).
- Test: `DBDriverHardeningTests` (jetzt 8): `testAuthErrorPacketIsNotLogged` (Proxy fälscht Auth-ERR mit Markern für User/Host/Text, Level info und trace), `testCloseDuringAuthentication…`, `testStalledTLSHandshake…`. Rot gegen HEAD und Mutationsprobe (Patches entfernt) belegt, siehe Übergabe `docs/handoffs/vendor-review2.md`.

## Aufbewahrung mit importierten Einsendungen im Browser (14.11.2026, Karte C174F624, QA D945BDCD, Worktree-Branch `worktree-agent-a05881df1bf99e040`)

- Befund fb-qa (Häkchen "Frist auch auf die importierten Einsendungen anwenden" + "Speichern und löschen": keine Anfrage, Frist blieb 3 Tage) ist **kein UI-Fehler in `RetentionPanel.svelte`**. Neuer Echt-E2E `backend/e2e-retention-ui.sh` + `pwa/e2e-real/real-retention-ui.spec.ts` (echtes Binary, Ziel- und Alt-MariaDB, `migrate-legacy`, Chromium mit virtuellem Authenticator, Aufbewahrungsjob alle 2 s) belegt: Dry-Run-Text stimmt mit der DB überein; Speichern ohne Häkchen = genau eine PUT ohne `applyToImported`, importierte Zeilen bleiben ohne Frist, Job löscht nichts; Abbrechen in jedem Dialog sendet nichts; Bestätigen = genau eine PUT `{days, applyToImported:true}`, Fristen gesetzt, Job löscht genau die fälligen (nicht gehaltenen) Zeilen, anderes Formular unberührt.
- Dialogfolge: Bei Verkürzen + Häkchen erscheinen ZWEI Dialoge nacheinander ("Aufbewahrung verkürzen" mit Knopf "Speichern und löschen", dann "Importierte Einsendungen einbeziehen" mit Knopf "Anwenden und löschen"). Erst der zweite löst die PUT aus. Ohne Verkürzung (Häkchen bei unveränderten 3 Tagen) gibt es nur den zweiten, dort existiert kein Knopf "Speichern und löschen". Wahrscheinliche Ursache des QA-Befunds: Testende nach dem ersten Dialog oder Knopf-Name aus dem ersten Dialog erwartet. Korrekt: `getByRole('alertdialog').getByRole('button', {name: 'Anwenden und löschen'})`. Offener UX-Vorschlag: beide Dialoge zu einem zusammenfassen.
- Zeilen ohne `received_at` bekommen auch mit Häkchen keine Frist (bestehendes Serververhalten, im Test berücksichtigt).
- Prüfung: Lauf grün (41 s), `E2E_RETENTION_UI_WRONG=1` rot, `check-e2e-rc.sh` grün, eslint/prettier/svelte-check 0, vitest RetentionPanel 6/6. CI-Schritt in `.github/workflows/ci.yml` (Ports 33739/33980).

## API-Host-Eigentümer (14.11.2026, Worktree-Branch `worktree-agent-acdbad1e1851f594c`, lokal committet, ungemergt; Todolino A4EDE0BE)

- Sicherheitsbefund (Opus, Abschnitt 3) behoben: `api_hosts.owner_customer_id` (Upgrade `0036-api-host-owner.sql`, in `MigrationRunner.upgrades`), `POST /api-hosts` und Domain-Anlage liefern Fremden 404 (kein 412/200-Orakel), Anhängen/Schalten nur Eigentümer oder `system.manage`. Bestand wird per Ersteller-Audit, sonst ältester Bindung zugeordnet (mehrdeutige Fälle: ADR 0045). ADR `docs/decisions/0045-api-host-eigentuemer.md`. PWA nutzt die Route nicht.
- Grenze: kein DNS-Nachweis, freie Namen können weiter vorab belegt werden. Nicht geprüft: Playwright/PWA (unverändert), Produktiv-Upgrade.

## Große Anhänge in Rotation, Hold, Flow, Verifikation (14.11.2026, Worktree-Branch `worktree-agent-a2bbe3d8ce2321e43`, lokal committet, ungemergt; Todolino C4D13F4D, 14298EC0)

- Lücke aus 985BC399 geschlossen (Prod-Blocker: Schlüsselrotation bei Anhang über ca. 12 MB scheiterte): `RotationRoutes` (Liste, Ersatzpaket-Schreiben), `HoldRewrapRoutes`, `FlowRunRoutes` (Kontext, Checkpoint-Read, Resume-Beweis), `FlowEngine` (Checkpoint-Insert/-Update), `MigrationVerificationRoutes` (Entschlüsselungsprobe) lesen/schreiben Objektzellen nur noch über `ChunkedBlob`; Zeilenabfragen laden `ciphertext` nicht mehr (`RotationRoutes.objectColumns`). `GET key-rotation/objects` begrenzt eine Seite auf ca. 32 MiB Pakete (mind. 1 Objekt, `next` wie bisher). Keine Vertrags-/Schema-Änderung.
- Tests (neu): `LargeObjectOperationsTests` (Rotation komplett inkl. Abschluss und Entschlüsselung mit neuem Schlüssel, Hold setzen/aufheben, Flow-Kontext und Resume-Beweis), `ImportRehearsalTests.testDecryptionProbeDeliversImportedPackageAbove16MiBWhole`, `MailEndToEndTests.testFullMailForSubmissionWithAttachmentAbove16MiB…`. Rot gegen HEAD (500 bzw. leere Listen), grün nach Fix. Alle mit 19,9-MB-Anhang (Paket 26,5 MB), Länge und SHA-256 der ganzen Zelle in der Datenbank geprüft.
- Mail (14298EC0): Mails tragen keine Anhänge (ADR 0041); Test belegt, dass ein 19,9-MB-Anhang Zustellung und Mailgröße nicht berührt. Kein SMTP-Größenlimit erreichbar. Doku `docs/BETRIEB.md`.
- Grenzen: Resume-Beweis hält alle Objekte einer Einsendung gleichzeitig im Speicher (nicht gemessen); Flow-Checkpoint über 16 MiB nur per Code, nicht per Test (Katalog begrenzt den Zustand auf 1 MiB); externer Speicher (S3/SFTP) nicht berührt. Übergabe `docs/handoffs/Grosse-Anhaenge-Wartung.md`.

## Sicherheitsbefunde mysql-nio-Review (S2-04b, S2-04c, Handshake-Timeout, SwiftPM-Konflikt) (14.11.2026, Worktree-Branch `worktree-agent-aa769c5a96d624821`, lokal committet, ungemergt, nicht gepusht; Todolino 26748F03, 8FA3A784, 927CCCEE)

- Quelle: Codex-Review der Patches (`orchestrator/runtime/fb-sec-codex-mysqlnio.md`). Vendoring der ganzen Kette `fluent-mysql-driver -> mysql-kit -> mysql-nio` nach `backend/Vendor` (Pfadabhängigkeiten, Root bindet nur den Treiber ein; SwiftPM-Warnung "Conflicting identity" entfällt, `Package.resolved` ohne diese Pakete). Patches und Update-Hinweis: `backend/Vendor/README.md` (`LOCAL PATCH`).
- S2-04b: MySQLKit reicht `queryLogLevel` in verschachtelten `withSession` weiter (MigrationService.tick -> LegacyImporter.run loggte Import-SQL samt Hex-Literalen). S2-04c: `MySQLQueryCommand.deinit` loggt/asserted kein SQL mehr. Handshake: `handshakeTimeout` (10 s) über Greeting/TLS/Auth, `channelInactive` schließt das Connect-Promise (Poolplatz wird frei).
- Tests (rot gegen HEAD belegt, dann grün): `FormPersistenceTests/DBDriverHardeningTests` (5, Fehlerproxy), `MigrationTests/testImportRunInNestedSessionLogsNoStatementsOrValues` (echter Importlauf). Übergabe: `docs/handoffs/mysqlnio-review.md`.

## Sicherheitsbefunde fb-sec 1+2 / S2-02: Byte-Budget für Request-Bodies (14.11.2026, Worktree-Branch `worktree-agent-a49f8dcdc9dd53998`, lokal committet, ungemergt, nicht gepusht; Todolino 3D410B52, 7C9A46D1, 049CE353, C6FCE0A3 nginx-Teil)

- Ursache (belegt): 16 parallele 30-MiB-Bodies ohne Login töteten den Container (512m) per OOM, an der Einsende-API (auch mit unbekanntem Formular: der Gate zählte nur Verbindungen, nicht Bytes) und an `PUT .../key-rotation/objects/{id}` sowie `PUT .../entries/{id}/hold` (Vapor sammelt `.collect(64mb)` vor dem Handler, also vor Anmeldung).
- Fix: `BodyBudget` (`FormCore`) = globales Budget reservierter Body-Bytes (Content-Length x 3, chunked = Routenlimit), Standard 128 MiB, `FORM_BODY_BUDGET_MB` (64-8192; compose/swarm/entrypoint/stack.env.example). `BodyBudgetGate` (`FormAuth`) läuft als Route-Middleware VOR dem Sammeln: zu große Content-Length 413 `payload_too_large`, Budget erschöpft 503 `body_budget_exhausted` + `Retry-After: 1`. Admin (`AdminBodyGate`): Session, Origin/CSRF und Request-Budget zuerst (anonym 401 ohne Pufferung), Request-Budget wird je Anfrage nur einmal belastet. Ingest: Formularbindung, Drosselung je Client, Medientyp und Signaturheader vor dem Body (`SubmitHandler.prepare`), Multipart ohne zweite Vollkopie. Kein Vertrags-, Schema- oder Migrationseingriff, kein ADR.
- nginx-Vorlage: `client_max_body_size` 33m (öffentlich) / 65m (intern), `X-Real-IP`, `limit_conn`, auskommentierter Block für Dashboard-Pfade; `deploy/proxy/test-template.sh` prüft `nginx -t` und die Grenzen (2/34/40/66 MiB). Doku: `docs/BETRIEB.md` (Abschnitt Betriebshärtung des Proxys).
- Tests: `Tests/FormCoreTests/BodyBudgetTests.swift`, `Tests/FormAdminTests/BodyBudgetRouteTests.swift` (echte MariaDB), Echtlauf `backend/e2e-body-budget.sh` (+ `e2e-body-budget-flood.py`), CI-Schritt in `e2e-real`. Rot gegen HEAD `2b340db`: alle vier Phasen `OOMKilled=true`; grün nach Fix: alle vier `OOMKilled=false` (Ingest 503/403, Admin 401).
- Offen: Budget gilt je Prozess; kein Test mit echtem Browser/nginx vor der App; Wirkung auf SDK-Wiederholung bei 503 nur aus dem Vertrag (503 retryable) abgeleitet.

## Sicherheitsbefunde S2-01 / S2-04: DB-TLS zwingend, kein Treiber-Logging von Geheimnissen (13.11.2026, Worktree-Branch `worktree-agent-a5a3849c493831cf8`, lokal committet, ungemergt)

- S2-01: Der Treiber mysql-nio sendete ohne `CLIENT_SSL` in der Serverbegrüßung weiter im Klartext (`isTLS: false`), auch bei `FORM_DB_TLS=verify`. Jetzt lokal eingebundener, gepatchter Treiber `backend/Vendor/mysql-nio` (Patches: `backend/Vendor/README.md`): ist TLS verlangt und fehlt `CLIENT_SSL`, bricht der Handshake mit `secureConnectionRequired` ab, bevor `SSLRequest` oder Handshake-Antwort geschrieben wird. Begründung: Nur im Treiber-Handshake ist die Entscheidung atomar; eine Vorabprobe oder ein Hook von außen kann die folgende, getrennte Verbindung nicht schützen. Dockerfile kopiert `backend/Vendor`.
- S2-04: `sqlLogLevel: nil` an allen drei Pools (Haupt-DB, Umstiegsquelle, Legacy-Befehl); `MySQLPacket.description` des Treibers gibt keine Payload-Bytes mehr aus (bei `trace` waren es 16 Bytes je Paket, bei `caching_sha2_password` über TLS inklusive DB-Passwort).
- Tests: `backend/Tests/FormPersistenceTests/DBTLSTests.swift` gegen echte MariaDB (Proxy entfernt `CLIENT_SSL`, zählt Client-Bytes). Rot gegen vorherigen Stand, grün nach Fix; Zahlen in `docs/handoffs/S2-01-S2-04.md`.
- Offen: kein Lauf gegen eine MariaDB mit `--skip-ssl` (Proxy-Entfernung des Flags ist auf dem Draht gleichwertig), kein `caching_sha2_password`-Server (MariaDB bietet ihn nicht), SwiftPM meldet die Warnung "Conflicting identity for mysql-nio" (gewollter Override).

## Große Uploads 500 (13.11.2026, Worktree-Branch `worktree-agent-a99e8714e8d8b2ed7`, lokal committet, ungemergt; Todolino 985BC399)

- Ursache belegt: MySQLNIO 1.9.2 teilt Pakete ab 16 MiB − 1 weder beim Schreiben noch beim Lesen (3-Byte-Länge), unabhängig von `max_allowed_packet` (gemessen: gebundener Wert 17 MB = "ok", gespeichert 0 Byte). Folge: Uploads 14 bis 19,5 MB = 500 (`MySQLError`), Inventar-`SELECT *` auf Zellen über 16 MiB = "storage maintenance failed" / "Statement not closed" jede Minute, Aufbewahrung/Wartungslöschung scheiterte dauerhaft an solchen Zeilen.
- Fix: `ChunkedBlob` (4-MiB-Stücke, CONCAT/SUBSTRING) für Ingest, `StorageService`, `DBObjectStore`, Spool; Inventarabfragen ohne `ciphertext`; `unhandled error` und Wartungswarnung loggen MySQL-errno/SQLSTATE (`DB.logDescription`). CI: eigener Schritt mit 64-MiB-DB (`DB_ARGS` in `ci-linux.sh`). Übergabe `docs/handoffs/Grosse-Uploads-500.md`.
- Geprüft: neue Tests `LargeUploadIngestTests` (12 bis 19,999999 MB: 200, Länge+SHA-256 in der DB, Anhang-Endpunkt byte-genau/entschlüsselt, Aufbewahrung löscht, Wartung beendet Löschung einer 21-MB-Zelle) und `LargeObjectRoundTripTests`; rot gegen HEAD, grün danach. Filter-Lauf FormStorage/Admin/Ingest/Flow/Migration auf 16-MiB-DB: 355 Tests, 0 Fehler. `ci-linux.sh` mit 64 MiB: 3 Tests grün.
- Offen: Rotation/Hold-Rewrap/Flow-Checkpoints lesen weiter ganze Zellen (Objekte über 16 MiB dort nicht nutzbar); PWA nicht berührt.

## QA-Befund Aufbewahrungsjob löschte importierte Einsendungen (13.11.2026, Todolino 32884165, Branch `worktree-agent-aaf4ecf27611b6ce9`, lokal committet, ungemergt, nicht gepusht)

- Ursache: Import setzte `retention_due_at = received_at + 3 Tage`; Alt-Einsendungen waren sofort fällig, der Job löschte sie. Fix: importierte Einsendungen ohne Frist (NULL), `PUT retention` nur mit `applyToImported` (+`dryRun`/`dueNowImported`), Upgrade 0035, Ledger-Nachweis ohne `retention_due_at` (Altnachweise weiter gültig, Freigabe prüft beide), Bericht `retention` (Schritt Prüfung), PWA-Dialog mit Häkchen/Bestätigung. Doku: ADR 0012 Nr. 2, UMSTIEG-CHECKLISTE 5a, BETRIEB.md.

## QA-Befund Upload-Verlust bei Anhang über DB-Paketgrenze (13.11.2026, Todolino 60B799DA, Worktree-Branch `worktree-agent-a5d49d428d8dd123a`, lokal committet, ungemergt, nicht gepusht)

- Befund im Ingest (Test `IngestPacketLimitTests`, echte MariaDB mit 4 MiB und 16 MiB): vorher HTTP 500 `internal_error`, Transaktion zurückgerollt, 0 Zeilen in submissions/stored_objects (im Ingest-Pfad KEIN stilles „angenommen“, das stille Erfolgsverhalten trat nur bei einer einzelnen Schreibanweisung ohne Transaktion auf). Antwort 500 hieß für Praxis/SDK „später erneut“, obwohl es nie gelingen kann.
- Fix: `PacketGuard` (FormIngest): Vorabprüfung des größten versiegelten Pakets gegen `@@session.max_allowed_packet` der Transaktionsverbindung (+64 KiB Reserve, nur ab 1 MiB) -> 413 `payload_too_large` VOR dem Schreiben mit Betreiberhinweis im Log; Nachprüfung der gespeicherten Objekte (Anzahl, Länge = byte_count) in der Transaktion -> sonst 503/Rollback; Startwarnung. Kein neuer Fehlercode (Vertrag/SDK unverändert, nur Klarstellung in contracts/ingest/README.md). Übergabe: `docs/handoffs/Upload-Verlust.md`.


## QA-Befund Import 1301 bei Altanhängen über ~12 MB (13.11.2026, Todolino 15C5D5E9, Branch `worktree-agent-afa358ab4744d9b7f`, lokal committet, ungemergt, nicht gepusht)

- Ursache: MariaDB prüft das Ergebnis des stückweisen `CONCAT(ciphertext, Teilstück)` gegen `max_allowed_packet` des Ziels (Standard 16 MiB). Fix: Vorabprüfung (größte Zelle der Quelle gegen Zielgrenze) im Prüflauf/Import mit benanntem Code `target_packet_too_small@<Ziel>:<Zelle>:<nötig>` VOR dem ersten Schreiben, Warnung in der Quellprüfung, Empfehlung 64 MiB (Doku Checkliste Punkt 7, BETRIEB). Normalbetrieb ebenfalls betroffen und still (gemessen: gebundener Wert über dem Limit wird vom Treiber als ok gemeldet, Zeile fehlt); Folgepaket nötig, siehe Übergabe.
- Belegt: Echtlauf `e2e-migration-packet.sh` rot (1301, schon geschrieben) -> grün (Ziel 16 MiB verweigert vorab, Ziel 64 MiB importiert 27-MB-Zelle byteidentisch); CI-Schritt ergänzt. Details: `docs/handoffs/QA-15C5D5E9.md`.

## QA-Befund Neuer Kunde ohne Altschlüssel-Feld (13.11.2026, Todolino 7B5E1E8A, Branch `worktree-agent-a4666f1971f08764e`, lokal committet, ungemergt, nicht gepusht)

- Befund bestand auf aktuellem main teilweise: Kunde ACTIVE und im Systemadmin-Listing (Fund A), aber Konto, Erweitert zeigte `#legacy-key-<kunde>` nicht, weil `session.tenants` beim Login geladen und nach dem Import nie erneuert wird. Fix: `Migration.svelte` ruft einmal je Importlauf `session.refreshTenants()`. Neuer Echtlauf `backend/e2e-migration-newcustomer.sh` (Ports 33726/33966/4326, CI-Schritt): erst rot (Feld fehlt), dann grün. Keine Mitgliedschaft nötig. Details: `docs/handoffs/QA-7B5E1E8A.md`. Kein Swift, kein Vertrag.

## Umstieg-Formular „detached from the DOM“ (13.11.2026, Todolino E47068F4, Branch `worktree-agent-a498d16b54bd44bd5`, lokal committet, ungemergt, nicht gepusht)

- Ursache belegt (kein Re-Render der Migration-Seite): `Tenants.create` rief nach `ensureCustomer`/`refreshTenants` verspätet `router.navigate` auf und zog Nutzer, die inzwischen „Umstieg“ geöffnet hatten, zurück zur Kundenseite (Formular aus dem DOM entfernt). Gleiches Muster in `Forms.create`. Fix: Flag `leftList`, kein spätes `navigate` nach Verlassen der Liste.
- Geprüft: vitest rot->grün (`Lists.test.ts`, 2 neue Tests), 525/525; Diagnose-Echtlauf (Binary + MariaDB + Chromium) vorher 3/3 rot, nachher 20/20 grün (15 normal, 5 mit 4x `yes`-Last); Notnagel in `real-migration-rotation.spec.ts` entfernt. Details: `docs/handoffs/Umstieg-Formular-Rerender.md`.

## Selbstsignierte Mailserver-Zertifikate je Verbindung (13.11.2026, Todolino 734F1761, Branch `worktree-agent-ad61bcd80cb131b86`, lokal committet, ungemergt, nicht gepusht)

- Nutzerentscheidung (Lino, Bestätigung in der App beim Review ausstehend): ADR 0044. `verifyCertificate:false` je SMTP-Verbindung produktiv erlaubt, nur ausdrücklich gesetzt, TLS bleibt Pflicht (`plain` weiter nur mit Dev-Schalter), Audit `connection.tls-verification-off`/`-on`, neuer `PUT /connections/{id}/tls-verification`. Ersetzt die Dev-Sperre der SMTP-TLS-Härtung; IP-SAN-Prüfung und Standard „prüfen“ bleiben.
- Import: Altwert `SMTPallowSelfSigned = 1` -> `verifyCertificate:false` (nur 1; 0/2/leer/unbekannt prüfen). Plan-Eingabe `verifyCertificateOff`, Hinweis im Umstieg; Golden `contracts/migration/rehearsal-golden.json` ergänzt.
- PWA: Schalter mit Warnhinweis, Kennzeichnung in der Liste, Menü „Zertifikatsprüfung wieder einschalten“. Details und Prüfungen: `docs/handoffs/SMTP-Selbstsigniert.md`.

## Freigabe importierter Einsendungen (13.11.2026, Todolino 2DC195BE, Branch `worktree-agent-a85ba50d422815162`, lokal committet, ungemergt, nicht gepusht)

- Neu: Knopf „Importierte Einsendungen freigeben“ im Umstieg-Schritt „Prüfung“ (`POST migration/jobs/{id}/release-submissions`): `migration-review` -> `accepted` für Einsendungen ohne offenen Prüffall mit bereitem `:2`-Paket, erst nach bestandener Probe (`test_hash` nicht verlangt), Ledger-Nachweis (`target_hmac`) in derselben Transaktion fortgeschrieben, keine neuen Effekte. Entscheidung kam als Brain-Kommentar, Bestätigung durch Lino in der App offen. Übergabe `docs/handoffs/Freigabe-importierter-Einsendungen.md`, ADR 0014, Checkliste, Lücke 15.
- Geprüft: Swift ROT ohne Route (17 Failures, 404), GRÜN 4/4, Mutation ohne Ledger-Fortschreibung rot (`conflict`); Echtlauf `e2e-migration.sh` rc=0 (falsche Erwartung rc=1), verify/existing/setup-umstieg rc=0; vitest 517/517. Das Echt-E2E hatte einen Race (Schlüsselanlage des Kunden per Poll abgewartet). Offen: Review, Merge.

## Einmal-Snapshot mit Schreibpause-Prüfung (13.11.2026, Todolino 48E3D133, Branch `worktree-agent-a92464679b4ae5a6d`, lokal committet, ungemergt, nicht gepusht)

- Nutzerentscheidung „B: Einmal-Snapshot, Quiesce-Prüfung im Code, kein Delta“ umgesetzt (ADR 0043, ersetzt den Delta-Teil von ADR 0033): Aktion `delta` entfällt (404), anderer Dump-Hash auf bestehendem Namespace = `snapshot_changed`, Quellen-Fingerabdruck (`CHECKSUM TABLE` + `COUNT(*)`, SHA-256) im Prüflauf-Bericht, Import prüft vor dem Schreiben (`source_changed`, nichts geschrieben) und nach dem letzten Objekt (`source_not_quiesced`, Lauf `failed`). Neue Job-Aktion `rehearse` („Prüflauf wiederholen“), `import` verlangt den Fingerabdruck (409 `source_fingerprint_missing` bei alten Jobs). CLI: `--expect-source-fingerprint`, Prüflauf druckt `source-fingerprint:`. 409 der Jobaktionen tragen Code und deutschen Text.
- Offen: `real-migration-rotation.spec.ts` und `e2e-migration-rotation.sh` nutzen noch das Delta und scheitern, bis die andere Session sie umstellt (Stufen siehe Übergabe `docs/handoffs/Einmal-Snapshot-Quiesce.md`). Kein Merge, kein Gesamt-Swift-Lauf, kein Review.

## migrate-legacy CLI-Funde (13.11.2026, Todolino A5F93B32, Branch `worktree-agent-a4ece33448519cd35`, lokal committet, ungemergt, nicht gepusht)

- Behoben: benannte Parameter-/Planfehler (Exit 2, stderr, nie Werte), toleranter `ImportPlan`-Decoder (optionale Felder mit Standardwerten, Pflicht: Namespace, Hash, Zuordnungen; kanonischer Plan-JSON/Digest unverändert, per Test mit festem Digest belegt), Exit 3 „abgeschlossen mit N offenen Prüffällen“, SIGINT/SIGTERM-Handler (Stopp an Objektgrenze, Exit 130/143, Sperre frei, Lauf nicht `running`), Statistikschlüssel ohne Kundengeneration und fehlende Freigabe als benannte Prüffälle `statistics-key-unknown` / `statistics-review-missing` (Zeilen nicht geschrieben, Rest läuft). Doku: `UMSTIEG-CHECKLISTE.md` (Exit-Code-Tabelle), Übergabe `docs/handoffs/CLI-Funde.md`.
- Bewusst offen: kein eigener Laufzustand `paused` (Schema-ENUM, Migration nötig); Teilcommit nach Mittenfehler bleibt (Pro-Objekt-Commit); Details in der Übergabe.

## Aufbewahrungsfrist Pflicht (13.11.2026, Todolino EEDF6CCE, auf main gemergt, nicht gepusht)

- Nutzerentscheidung „Einheitlich 72 h als Voreinstellung, änderbar“: Frist je Formular ist Pflicht (Standard 3 Tage, 1–3650), kein Abschalten (`PUT null` = 422), Freigabe ohne Frist = 409 „Aufbewahrungsfrist fehlt“. Import setzt Frist und Fälligkeit; Aufbewahrungsjob und Friständerung respektieren fortsetzbare Importe. Upgrade `0034-retention-default.sql`: Bestand älter als 3 Tage wird danach beim nächsten Job-Lauf gelöscht (vor Rollout ankündigen). ADR 0012 Nr. 2, Übergabe `docs/handoffs/Aufbewahrungsfrist-Pflicht.md`.
- Geprüft: `PrivacyTests` 10/10 (4 neu, rot-gegen-alt nicht einzeln belegt), Filter MigrationTests/ImportRehearsal/JobImporter/SetupMigration 56/56, vitest 514/514 (RetentionPanel 4 neu), svelte-check 0 Fehler, eslint grün; `prettier --check` meldet nur die fremde Datei `real-migration-rotation.spec.ts`. Echt-E2E `e2e-retention.sh` rc=0, `E2E_RETENTION_WRONG=1` rc=1, `check-e2e-rc.sh` rc=0; `e2e-migration.sh` rc=0 (2 frühere Fehlläufe an der Zeitrennen-Prüfung vor dem Import), `e2e-migration-convert.sh` rc=0, `e2e-migration-existing.sh` rc=0. Offen: Gesamt-Swift-Lauf, Review.

## E2E Entwürfe aus dem Import (13.11.2026, Todolino 7D503F6B, Branch `worktree-agent-a43157213326dc7d4`, lokal committet, ungemergt, nicht gepusht)

- Neu: `backend/e2e-migration-convert.sh` + `real-migration-convert.spec.ts` (CI-Schritt „E2E Umstieg drafts“): Import bis `review`, Knopf „Entwürfe und Konverterbericht erstellen“, 3 Entwürfe / 6 von 7 Feldern, Wiederholung ohne Änderung, Editor, 409. rc=0 (ca. 35 s), falsche Erwartung rc=1, `check-e2e-rc.sh` grün. Lücke 6 ist durch `real-migration.spec.ts:150-206` belegt, Lücken 6 und 7 in der Liste erledigt.
- Fund behoben (Branch `fix/release-nach-import`): Veröffentlichen eines konvertierten Entwurfs endete mit HTTP 500, weil `ReleaseRoutes.version()` nur `resource_versions` zählte und mit `form_versions` Nr. 1 des Imports kollidierte. Jetzt liegt die nächste Formularversion über beiden. Test `ReleaseVersionNumberTests` (rot 1 statt 2, dann grün), der Echtlauf verlangt 201 und die Versionen `1,2` (gegen den alten Code 500, rc=1). Weiter offen: Der Import konvertiert selbst (der Knopf wiederholt nur), und der 409 kommt ohne Grundtext. Übergabe `docs/handoffs/E2E-Migration-Konverter.md`.

## Swift-Gesamtlauf-Absturz „Statement not closed“ (13.11.2026, Todolino 2C1378DF, Branch `worktree-agent-aee79aecd6a32572f`, lokal committet, ungemergt)

- Nicht reproduzierbar: Gesamtsuite auf main b59780e plus Änderung rc=0 (536 Tests, 6 übersprungen, 7:25 min), Teilfilter grün. `ImportTargetPreconditionTests` ist nur eine Extension von `ImportRehearsalTests` (keine Unterklasse, nichts läuft doppelt).
- Belegt (Absturzberichte `xctest-*.ips`): die Assertion steht im `deinit` von `MySQLQueryCommand`, ausgelöst aus `MySQLConnectionHandler.channelInactive` nach `readEOF`: der Datenbankserver hat die Verbindung mitten in der Abfrage beendet (Umgebung, kein Verwerfen im Produktcode). Ein zweiter Bericht zeigt dieselbe Ursache am anderen Ende (`CREATE DATABASE` scheitert, Application ohne Shutdown).
- Geändert: `AdminFixture.with` fährt bei gescheitertem `CREATE DATABASE` die Admin-Application herunter (echter Fehler statt Vapor-Assertion); `integration-test.sh` gibt bei rc≠0 Container-Zustand (OOM, Neustart) und Serverlog aus. Offen: bei erneutem Absturz diese `diag:`-Zeilen auswerten. Übergabe `docs/handoffs/Gesamtlauf-Absturz-mysql-nio.md`.

## Lasttest, Failover-Probe und rc-Prüfung (13.11.2026, Todolino 3A140F21, Branch `fix/loadtest-failover`)

- `backend/loadtest.sh` setzt `FORM_INGEST_REQUESTS_PER_MINUTE=0` (überschreibbar mit `LOADTEST_INGEST_LIMIT`): Der Lasttest misst Durchsatz und Idempotenz, alle Worker teilen eine IP. Ergebnis: 458 von 458 ok, p95 89 ms, 401 gespeichert gleich 401 eindeutig, /ready 200. Gegenprobe mit Limit 60: 398 mal 429, rc=1.
- `backend/e2e-failover.sh` lokal grün (alle 14 Prüfungen). Die Bereitstellung per Playwright prüft in beiden Skripten den eigenen rc statt `| tail`. `scripts/check-e2e-rc.sh` verbietet jetzt jede Pipe hinter `playwright test` (die alte Fassung beider Skripte wird erkannt).
- e2e-login „Dienst nicht erreichbar“: kommt von HTTP 500/503 beim Passwortschritt (`Login.svelte:105`). In 5 Läufen auf main 977fb8b nicht reproduziert. Bei erneutem Auftreten hilft `E2E_LOG_DIR` (app.log).

## Admin-Anfragelimit (13.11.2026, Todolino 63A481E7, Branch `worktree-agent-a9dcbd404dbb0e66f`, lokal committet, ungemergt, nicht gepusht)

- Admin-API: IP-Grenze 600/min (alle Anfragen) plus Kontobudget `acct|<ID>` 300/min für angemeldete Sitzungen, per `FORM_ADMIN_REQUEST_LIMIT_IP`/`_ACCOUNT` (1 bis 100000, sonst Startfehler); Login- und Fehlversuchsgrenzen unverändert. PWA zeigt bei 429 „Zu viele Anfragen. Bitte in N Sekunden erneut versuchen.“
- Geprüft: Swift (neue Tests rot gegen alt, dann grün), vitest, Echt-E2E `backend/e2e-admin-limit.sh` (gegen alt rot, regulär rc=0, falsche Erwartung rc=1; CI-Schritt im Job `e2e-real`). Übergabe `docs/handoffs/Admin-Anfragelimit.md`.

## Umstieg-UI: 409, Schlüssel-ID, Abschlusszustand (13.11.2026, Todolino CF9547A6, Branch `worktree-agent-a99562cb772d96aaf`, lokal committet, ungemergt, nicht gepusht)

- PWA `Migration.svelte`: 409 hat eine eigene Meldung (Zustandskonflikt statt „Verbindung unterbrochen“); „Altzugriff entfernen“ ist ohne Probe und Testnachricht gesperrt mit Hinweis „Noch offen: …“; die Probe zeigt die benötigte Schlüssel-ID (aus dem Wire, Backend unverändert); ein geschlossener Lauf zeigt „Umstieg abgeschlossen“ mit Erledigtem, ohne Aktionen.
- Geprüft: vitest rot/grün, Echt-E2E `e2e-migration-verify.sh` erweitert. Übergabe `docs/handoffs/Umstieg-UI-409-kid-closed.md`. Lückenliste 4/5 ergänzt.

## Ops-Liste: Uhrversatz App/DB (13.11.2026, Todolino 05A35EB7, Worktree `.claude/worktrees/fb-nacht-ops`, Branch `fix/ops-uhrversatz`)

- Ursache des flaky `OpsDatabaseTests.testLiveRightsPagingChronologyAndCleanup` (`page.next!` nil): Die Trigger stempeln `ops_events.occurred_at` mit der DB-Uhr, `GET /ops` hat ohne `to` aber `occurred_at <= now()` nach App-Uhr gefiltert. Läuft die DB-Uhr vor (Docker-VM-Drift, getrennter DB-Host), fehlten die neuesten Ereignisse in Liste und Paging. Fix: ohne `to` gibt es keine obere Grenze (OpsRoutes.swift); ein ausdrückliches `to` gilt weiter.
- Tests: neuer DB-Test `testDefaultWindowShowsEventsStampedAheadOfTheAppClock` (vorher rot, jetzt grün), `page.next!` durch `XCTUnwrap` ersetzt. Echter Browser-E2E `backend/e2e-ops.sh` + `pwa/e2e-real/real-ops.spec.ts` (Ports 33742/4332, CI-Schritt im Job `e2e-real`): echte Trigger-Ereignisse aus zwei Zustellungen, der offene Alarm 10 min vorgestempelt. Die Ansicht „Betrieb“ zeigt ihn in der Alarmansicht (Standard) und in der Gesamtliste. Gegen den alten Code rc=1 (Alarm fehlt), mit `E2E_OPS_WRONG=1` rc=1, regulär rc=0 (ca. 30 s).
- Swift-Gesamtlauf-Absturz (mysql-nio „Statement not closed“, Todolino 2C1378DF): siehe Abschnitt oben, nicht reproduzierbar, Diagnose ergänzt.

## Umstieg: Zertifikatsfehler der Quelle benannt (13.11.2026, Todolino 443C1306, Branch `worktree-agent-a5be5349c3d1b12c0`, lokal committet, ungemergt, nicht gepusht)

- `source_cert_hostname`/`source_cert_untrusted`/`source_cert_expired` statt `source_failed`; unbekannte CA vs. abgelaufen per Diagnoseverbindung (nur SSLRequest, nie Zugangsdaten). Echter Treiberfehler: `NIOSSLError.handshakeFailed(CERTIFICATE_VERIFY_FAILED)`, Hostname `NIOSSLExtraError.failedToValidateHostname`. PWA-Texte, Checkliste, Lücke 13(a) behoben. Übergabe: `docs/handoffs/Zertifikatsfehler-Quelle.md`.
- Geprüft: Swift `SourceCertificateTests` rot (3 Fake-TLS-Fälle generische Meldung), dann `SourceCertificateTests|ImportRehearsalTests|SourceTLSProbeConnectTests|MigrationServiceTests` 25 grün; `bash backend/e2e-migration-tls.sh` (Image aus diesem Stand) rc=0, falsche Erwartung rc=1; svelte-check 0, eslint, prettier sauber. Offen: Swift-Gesamtlauf, Image-Build durch Koordinator.

## E2E-Skripte: eindeutige Container-/Netznamen (13.11.2026, Todolino FC16624F, Branch `worktree-agent-a348aefe90a84c82f`, lokal committet, ungemergt, nicht gepusht)

- Ursache der Kollisionen (feste `p4a-*`-Namen, `docker rm -f NAME` am Start/im Cleanup, geteilte `pwa/dist`/`test-results`) behoben: `backend/e2e-common.sh` (Lauf-ID, `e2e_name`, Labels `e2e.run`/`e2e.started`, Cleanup nur per eigenem Label, Stale-Reaper nur per Label > 6 h, freie Ports wenn nicht gesetzt, PWA-Build/Playwright-Output je Lauf). Alle `backend/e2e-*.sh`, `smoke-admin.sh`, `loadtest.sh`, `proxy-probe.sh` umgestellt; CI unverändert (setzt Ports, keine Namensverweise). Regel: `docs/ENTWICKLUNG.md`; Übergabe: `docs/handoffs/E2E-Eindeutige-Namen.md`.
- Geprüft: `scripts/check-e2e-rc.sh` grün; `scripts/test-e2e-parallel.sh` ROT gegen alte e2e-setup.sh (rc_a=2, Containername belegt), GRÜN danach (mit/ohne Ports); Rotation 5x nacheinander 4x grün, 1x rot (Spec-Flake `audit_events=6` statt 5, unabhängig von Kollisionen, offen); Rotation 2x parallel grün; 7 verschiedene Skripte gleichzeitig grün; danach nichts Gelabeltes übrig.
- Flake `real-migration-rotation.spec.ts:192` geklärt (Todolino 47670928): Ereignis `key.recovery.read` der Browser-Automatik (30-s-Takt), Test filtert es; Details `docs/handoffs/E2E-Migration-Rotation.md`. Offen bleibt ein anderer, seltener Flake in `checkSource` (Feld „detached“, 4 von 28 Läufen); `e2e-migration-tls.sh` lokal nicht gelaufen (Image/Linux nötig).

## Import-Vorbedingungen benannt (13.11.2026, Todolino 3D929604, Worktree `.claude/worktrees/agent-adcbd9e681fc09e76`, Branch `worktree-agent-adcbd9e681fc09e76`, lokal committet, ungemergt, nicht gepusht)

- Aktive/veröffentlichte Zielformulare: Jobcode `target_forms_live` statt `invalid_plan`; abweichender Zielkundenname: `customer_name_mismatch` (Abbruch vor dem Schreiben, auch im Prüflauf, keine Run-Zeile). Formular-/Kunden-IDs nur im Server-Log. Kein Depublizieren im Produkt; Meldung und `docs/UMSTIEG-CHECKLISTE.md` nennen nur Import vor dem Live-Gang, frisches Ziel, Wiederherstellung. Swift rot/grün (56 Tests), Echtlauf `e2e-migration-existing.sh` grün. Image `form-backend:024bbdd62a5f`, Smoke ok. Offen: Vorwarnung im Plan-Schritt. Übergabe `docs/handoffs/Import-Vorbedingungen.md`.
## Echter E2E: `migrate-legacy` als Prozess und Statistik-Import (13.11.2026, Todolino 08B5E8E4, Worktree `.claude/worktrees/agent-af04249794cada6de`, Branch `worktree-agent-af04249794cada6de`, lokal committet, ungemergt)

- `backend/e2e-migration-cli.sh` (echte Binary je Aufruf, echte Quell-/Ziel-MariaDB, kein Browser): Parameter-/Planfehler, Prüflauf, Import, Wiederholung, SIGINT/SIGTERM mit Wiederaufnahme, Statistik mit/ohne Freigabe und Schlüssel (kein Klartext im Ziel-Dump), keine Geheimnisse in Ausgaben. Lokal grün: 93 Prüfungen, 129 s; absichtlich falsche Erwartung (`E2E_CLI_WRONG=1`) endet mit Exit 1. CI-Schritt im Job `e2e-real` (Ports 33736/33977). Gemeinsamer Fingerprint `backend/e2e-migration-fingerprint.sql` (von `e2e-migration-restart.sh` mitgenutzt, dessen Lauf nach der Änderung NICHT neu ausgeführt wurde: nur `bash -n`). Zusatzdaten `Fixtures/legacy-synthetic-statistics-extra.sql`. Funde und Grenzen: `docs/handoffs/Migration-E2E-Luecken.md` (11, 12), Übergabe `docs/handoffs/E2E-Migration-CLI-Statistik.md`. Kein Produktcode geändert.

## Setup-Assistent: 3 Funde behoben (13.11.2026, Todolino 4C675763, Branch `worktree-agent-a4f6c82326d5c089f`, lokal committet, ungemergt)

- Importstand statt Jobzahl: Umstieg-Schritt erst nach echtem Import (Lauf `dryRun=false` in review/verified/closed) erledigt, Prüflauf/laufender Lauf nur als Hinweis; Kunden-Schritt zeigt „Kunde aus dem Umstieg importiert, wird beim Live-Gang aktiviert“ (ohne neue Backend-Route); `ensureCustomer` unterscheidet gesperrt (Weg: Konto → Mit Passkey entsperren / Recovery-Code) von nie eingerichtet; die Meldung bleibt auch nach dem Anlegen des Kunden sichtbar.
- Geprüft: vitest rot (6 failed | 22 passed in onboarding.test/automation.test) dann 503/503, svelte-check 0, eslint, prettier sauber, Playwright setup-migration/setup-flow/admin 97 grün (2 neue), Echtlauf `bash backend/e2e-setup-umstieg.sh` rc=0 (1 passed, Reload-Fall real geprüft). Übergabe: `docs/handoffs/Setup-Assistent-Funde.md`.

## Echter E2E: Import über Dienstneustarts (13.11.2026, Todolino 73F6712E, Worktree `.claude/worktrees/agent-a16e08182da58b744`, Branch `worktree-agent-a16e08182da58b744`, lokal committet, ungemergt, nicht gepusht)

- `backend/e2e-migration-restart.sh` + `pwa/e2e-real/real-migration-restart.spec.ts`: Import im laufenden Dienst, dreimal mitten im Lauf unterbrochen (kill -9, SIGTERM, Pause-Taste), Neustart auf gleicher DB, Zustand „pausiert“, Fortsetzen, Endzustand gleich einem ungestörten Import (Fingerprint, zweite DB), Delta ohne Änderung. Lokal grün, 130 s; CI-Schritt im Job `e2e-real` (Ports 33717/33955/4316). Übergabe: `docs/handoffs/E2E-Neustart-Import.md`, Lücke 3 in `Migration-E2E-Luecken.md` geschlossen.
- `backend/e2e-migration-verify.sh` + `pwa/e2e-real/real-migration-verify.spec.ts` (13.11.2026, Todolino 45CA2550): Umstieg-Verifikation echt (Binary, Quell-/Ziel-MariaDB, Chromium, Ports 33720/33960/4320): Import, Entschlüsselungsprobe im Browser (falscher Schlüssel verweigert, Altschlüssel bestätigt), lokale Testnachricht, "Altzugriff entfernen" (vorher 409, danach Zugangsdaten weg, Daten/Bericht unverändert, geschlossener Job verweigert alles). Lokal grün (32 s warm), CI-Schritt im Job `e2e-real` eingetragen, noch nicht in der CI gelaufen. Funde: `docs/handoffs/E2E-Migration-Verify.md`. Kein Produktivcode geändert.
- `backend/e2e-migration-tls.sh` + `pwa/e2e-real/real-migration-tls.spec.ts` (13.11.2026, Todolino 22EF52A6, Worktree `.claude/worktrees/agent-acc4f0d39c7566344`): Quellprüfung/Import über echte Quell-MariaDB mit TLS (Wegwerf-CA): verify ok, falscher Hostname/unbekannte CA/abgelaufen scheitern im Handshake, ohne TLS `source_no_tls` ohne Login-Ereignis an der Quelle, disable mit Warnung, Import bis Prüfbericht. Lokal grün (23 s, App aus Image `form-backend:latest`), CI-Schritt eingetragen (Host-Modus, CA per sudo im Runner, Ports 33735/33975/33976/4335), in der CI und im Host-Modus noch nicht gelaufen. Funde: Zertifikatsfehler ungenannt (`generic`), kein CA-Feld. Details: `docs/handoffs/E2E-Migration-TLS.md`. Kein Produktivcode geändert.
- `backend/e2e-setup-umstieg.sh` + `pwa/e2e-real/real-setup-umstieg.spec.ts` (13.11.2026): Setup-Assistent mit Umstieg in einem Zug, echt (Binary, Quell-/Ziel-MariaDB, Chromium). Lokal grün, 26 s; CI-Schritt im Job `e2e-real` (Ports 33718/33957/4317), noch nicht in der CI gelaufen. Lücke 8 in `Migration-E2E-Luecken.md` geschlossen; Funde und Übergabe: `docs/handoffs/E2E-Setup-Umstieg.md`. Branch `worktree-agent-aafe3aa8383708d09`, ungemergt.
- `backend/e2e-migration-existing.sh` + `pwa/e2e-real/real-migration-existing.spec.ts` + `existing-helpers.ts` (13.11.2026, Todolino 493222EE): Umstieg in einen VORHANDENEN Kunden mit eigenen Daten, echt (Binary, Quell-/Ziel-MariaDB, Chromium, Ports 33722/33962/4322, Container `p4a-ex-*`). Zeilen-Fingerprint der Eigendaten (alle Tabellen mit `customer_id` + Kunde + Verbindungen + Secrets) bleibt über alle Läufe byte-gleich; 7 Kollisionsfälle einzeln. Lokal grün (66 s), CI-Schritt im Job `e2e-real`, noch nicht in der CI gelaufen. Lücke 9 geschlossen; Funde (veröffentlichtes Formular blockiert jeden Import als `invalid_plan`, falscher Kundenname unbenannt): `docs/handoffs/E2E-Migration-Existing.md`. Branch `worktree-agent-a8856ac8240af9038`, ungemergt. Kein Produktivcode geändert.
- `backend/e2e-migration-rotation.sh` + `pwa/e2e-real/real-migration-rotation.spec.ts` (13.11.2026, Todolino 9CE316EC): Umstieg x Schlüsselrotation, echt (Ports 33781/33991/4381, Container `p4a-rimp-*`). Lokal grün (~60-80 s, 3 Läufe), rot→grün belegt (falsche Erwartung `conflict` statt `missing_target` gab rc=1), CI-Schritt im Job `e2e-real`, noch nicht in der CI gelaufen. Kernfunde: Rotationsbeginn nach jedem Import global blockiert (nichts setzt `activated`), Browser-Automatik hängt beide Altgenerationen von selbst um und schließt ab, Delta danach `missing_target`, SQL-Workaround `accepted` bricht das Delta (`conflict`). Lücke 10 geschlossen; Übergabe `docs/handoffs/E2E-Migration-Rotation.md`. Branch `worktree-agent-a1fe8d6589d1e9e5d`, ungemergt. Kein Produktivcode geändert.
- Produktfund: keiner, der Daten betrifft. Beobachtung: nach SIGTERM bleibt der Auftrag `running` (Recovery beim Start macht `paused`). Keine Produktcodeänderung.

## Altformat-Payload in der Einsendungsansicht (13.11.2026, Todolino F4892F45, Worktree `.claude/worktrees/agent-afcd752ff8cf92bc6`, Branch `worktree-agent-afcd752ff8cf92bc6`, lokal committet, ungemergt, auf main fast-forward)

- Detailansicht zeigt flache Alt-Payloads (Feldname → Wert) mit lesbar gemachten Namen; Parser `pwa/src/lib/entries/payload.ts`, Format und Beschriftungsgrenzen: `docs/handoffs/Alt-Payload-Format.md`. `real-migration.spec.ts` prüft Namen und Werte des synthetischen Dumps (Lauf rot vor, grün nach der Änderung). Der SQL-Workaround `migration-review` → `accepted` in der Spec bleibt unverändert (offene Entscheidung).
- Geprüft: svelte-check, eslint, prettier, vitest (85 Dateien, 498 Tests), Playwright-Mock `admin`/`screens` (81 bestanden, 8 übersprungen), `backend/e2e-migration.sh` grün. Keine Beschriftung aus Formulardefinition (nur Feldname vorhanden).

## Real-E2E MCP repariert, e2e-admin.sh entfernt (13.11.2026, Todolino 27903673, Worktree `.claude/worktrees/agent-a23e5ce28078b282e`, Branch `worktree-agent-a23e5ce28078b282e`, lokal committet, ungemergt)

- `real-mcp.spec.ts` an die neue UI angepasst (Seite `/api-tokens`, Token-Dialog mit Kundenauswahl, Zustimmungs-Panel auf `/api-tokens?oauth_request=`, Auswahlfelder statt UUID-Eingabe). Sicherheitsaussagen unverändert. Der Admin-API-Budget (120 Anfragen/min/IP, `AuthGuard.requestBudget`) wird durch die SPA-Seitenladungen erschöpft; die Spec wartet vor dem Zustimmungsschritt und vor dem Widerruf auf das nächste Minutenfenster (+~2 min Laufzeit).
- `backend/e2e-admin.sh` entfernt (Spec `real-admin` ist `test.skip`, ersetzt durch `real-setup`); `real-load-setup.spec.ts` auf die Helfer umgestellt (lokal für `loadtest.sh`/`e2e-failover.sh`, nicht in der CI).
- Offen: `backend/loadtest.sh` schlägt fehl, weil das Ingest-Limit (`ingest.requestsPerMinute`, `IngestRoutes.swift:79`) 340 von 400 Anfragen mit 429 beantwortet; Skript muss das Limit setzen (Erwartung "kein 429" veraltet). `/ready public=404` in derselben Ausgabe ungeklärt. `e2e-login.sh` schlug einmal transient fehl ("Dienst nicht erreichbar" bei falschem Passwort), zwei Wiederholungen grün.

## Browser-Real-E2E Umstieg (12.11.2026, Todolino E1FB39C0, Worktree `.claude/worktrees/agent-ac3ec0713a6b898cb`, Branch `worktree-agent-ac3ec0713a6b898cb`, lokal committet, ungemergt, baut auf `agent/migration-datenschluessel`)

- Synthetischer Altdump `legacy-synthetic.sql` + Generator; `backend/e2e-migration.sh` läuft ohne Kundendump (echte Binary, Ziel- und Quell-MariaDB, Chromium) und in der CI (Job `e2e-real`). Lokal grün, 44 s gesamt. Kette und Grenzen: `docs/handoffs/Browser-Real-E2E-Migration.md`, `Migration-E2E-Luecken.md` Punkte 1/2.
- Offene Produktfunde (nicht umgangen, nur gemeldet): importierte Einsendungen bleiben `migration-review` und sind nirgends les-/listbar; Detailansicht zeigt flachen Alt-Payload ohne Felder; `e2e-*.sh` melden Playwright-Fehler nicht als Fehlerstatus.

## Umstieg: Fehler "Phase datenschluessel, Datenbankfehler" (12.11.2026, Todolino 72E982B5, Worktree `~/Development/worktrees/fb-migfix`, Branch `agent/migration-datenschluessel`, lokal committet, ungemergt)

- Importer meldet Zielfehler jetzt als `database@<Fehlernummer>[:<Indexname>]` (nie Werte), Log `migration job failed ... table= code= sqlstate= object=`. Schlüssel-Vorabprüfung (auch im Prüflauf): Konflikte mit dem Ziel/Plan als `key_conflict_active|number|publickey|plan`; gleiche Generation (kid + Public Key) im Ziel wird übernommen; `erstelltAm=0` ergibt `created_at` 1970-01-01 statt NULL-Fehler.
- Ursache des Produktionsfalls ohne Log nicht eindeutig; belegte Klasse: UNIQUE-Verletzung (1062) auf `customer_key_generations`. Fortsetzen scheiterte an derselben Ursache (kein Resume-Fehler).
- Tests: `ImportKeyPhaseTests` (7, rot gegen alten Code, grün), `ImportDatabaseDiagnosticsTests`, Vitest/Playwright-Ergänzungen. Lücken: `docs/handoffs/Migration-E2E-Luecken.md`; Übergabe: `docs/handoffs/Migration-datenschluessel-Bug.md`.
- Offen: Review/Merge; Playwright-Real-E2E mit Import (braucht synthetischen Dump).


## Mail an das Team: Standard mit allen Angaben (13.11.2026, Todolino 4287D708, Worktree `.claude/worktrees/agent-ae612fe6352d34fc0`, Branch `worktree-agent-ae612fe6352d34fc0`, ungemergt)

- Entscheidung Nutzer 13.11. (ADR 0041 geändert): Das Praxisteam hat keinen Backend-Zugriff, alles muss in der Mail stehen, wie im Altbackend. `content` fehlt = `full` (neu, alt, importiert). Ohne Vorlage Standard-Betreff „Neue Einsendung: <Formularname>“ und Feldliste `Beschriftung: Wert` (Altbackend hatte keine Standardvorlage). `notification` nur durch ausdrückliche Wahl im Mail-Reiter; Audit `release.mail-fulltext` und Warnhinweis entfernt, keine zusätzlichen Hinweise.
- Code: `FormMail/MailPlan.swift` (Default full, Vorlage optional, `fields`), `MailNotification.swift` (`MailStandard`), `MailDispatcher.swift` (Fallback je Teil, Wiederversand gleich), `ReleaseRoutes.swift` (Audit entfernt), PWA `MailTab.svelte`/`draft/mail.ts`/`de.ts`, Schema + `validate.py`. Übergabe `docs/handoffs/Mail-Standard-voll.md`.
- Offen: Reihenfolge der Feldliste folgt den Feld-IDs, nicht dem Ansichts-Layout; Feldauswahl je Vorlage und Einzeleintrags-Deep-Link nicht umgesetzt. Vor dem Rollout kein Hinweis an die Praxis nötig (Verhalten wie Altbackend).

## SMTP-TLS-Härtung (11.11.2026, Worktree-Branch `worktree-agent-a5d7f9391f8247db0`, lokal committet, ungemergt)

- (Überholt durch ADR 0044, 13.11.2026: Sperre zurückgebaut, Option je Verbindung erlaubt.) `verifyCertificate:false` bei SMTP nur mit `FORM_ALLOW_INSECURE_DEV`; produktiv Fehler beim Anlegen (422) und beim Transportaufbau (`MailConnection.transport`, zusätzlich `insecure_not_allowed` im `SMTPTransport`). Gespeicherte Altverbindungen mit `false` senden produktiv nicht mehr; vor Rollout umstellen.
- IP-Literale: Hostprüfung wirkte schon (NIOSSL: kein SNI für IPs, Abgleich der verbundenen Adresse gegen IP-SAN, nie CN); jetzt mit Tests (passende IP-SAN ok, andere IP-SAN und fehlende IP-SAN scheitern). Details und Grenzen: `docs/handoffs/SMTP-TLS-Haertung.md`.
## Audit-Lese-API und PWA-Protokoll (11.11.2026, Todolino 3299A88F, Worktree-Branch `worktree-agent-a700b31cb123b21a1`, lokal committet, ungemergt)

- FA-146: `GET /admin/api/v1/audit` mit `audit.read` (Bereich je Grant: System, Kunde, Formular), Filter Zeitraum/Aktion/Akteur (+ Bereich, Kunde, Formular), Keyset-Paginierung, nur Metadaten, no-store, kein Step-up. PWA `/audit` („Protokoll“, Gruppe System) mit Filter, Leer-/Fehlerzustand, Kartenliste mobil. Übergabe: `docs/handoffs/Audit-Lese-API.md`. Unabhängiges Review steht aus.
## Backups verschlüsseln, Offsite, Aufbewahrung, Restore-Nachweis (12.11.2026, Worktree-Branch `worktree-agent-af828e2c59c37173c`, lokal committet, ungemergt)

- `backup-db.sh` verschlüsselt per Pipe (age bevorzugt, gpg alternativ), fail-closed ohne Empfänger; `restore-db.sh` entschlüsselt per Pipe nach Prüfsummenprüfung. Neu: `backup-crypto.sh`, `backup-offsite.sh` (rclone/rsync, Verifikation), `backup-prune.sh` (Standard 30 Tage, Klinik entscheidet), `test-backup-crypto.sh`.
- Geprüft: `scripts/test-backup-crypto.sh` 36 bestanden (gpg und age lokal, Wegwerf-MariaDB); `check-deploy.py` Backup/Restore-Verträge angepasst. Protokoll `docs/betrieb/restore-probe-2026-11-12.md`, Übergabe `docs/handoffs/Backup-Verschluesselung.md`.
- Offen: echtes Offsite-Ziel (Betreiberentscheidung), rclone/ssh real, Server-Key-Restore mit echter App.
## Bug „Zugriff / Schlüssel entsperren geht nicht“ (12.11.2026, Worktree-Branch `worktree-agent-a83397b693a1cf4cc`, lokal committet, ungemergt, nicht gepusht)

- Todolino 2DDA1979. Details von Lino fehlen (Frage am Board offen, nicht blockierend). Basisweg (Passkey mit PRF, Recovery-Code, Altschlüssel-Übernahme, Frischefenster) läuft im echten E2E. Belegte Fehlerklassen, jetzt behoben: (1) importierte aktive+auslaufende Generation ohne Zugang: Hintergrund-Automation öffnete nach 30 s ungefragt den Passkey-Dialog und rief alle 30 s `key-recovery` (auditiert) auf; (2) Passkey ohne PRF: falsche Meldung „noch keinen Kontoschlüssel“; (3) falscher Code, fehlende Recovery, verweigerte Bestätigung: nur „Das hat nicht geklappt“.
- Fix: `GET key-recovery` → 404 `recovery_missing` (nur nach Rechteprüfung); PWA-Hintergrundreparatur `quiet` (kein Dialog), Merker je Sperre, benannte Meldungen (`de.ts`). Keine Migration, keine Schlüssel-/Datenänderung, Zero-Knowledge und Step-up unverändert.
- Tests: Swift `KeyManagementTests` (neu `testImportedStateRecoveryNamesTheCause`), echtes E2E `backend/e2e-unlock.sh` mit `pwa/e2e-real/real-unlock.spec.ts` (PRF) und `real-unlock-noprf.spec.ts` (`E2E_NO_PRF=1`), beide im CI-Job „Real end-to-end runs“. Veraltete `real-*`-Helfer repariert (CI-Job war mit alten UI-Texten nicht lauffähig); `real-migration.spec.ts` bleibt darüber hinaus veraltet.
- Swift-Gesamtlauf nicht vollständig: Abbruch in `OpsTests.swift:63` (einzeln grün), betroffene Filter (Key/Rotation/AccountRecovery/SetupMigrationKey) 19/19 grün.
- Offen: echter Browser/Passkey-Manager, Safari, echter Altschlüssel; Bedienung der Freigabe nach Neuladen bleibt umständlich (gemeinsamer Entsperrdialog nicht gebaut). Übergabe mit Schritten für Lino und Zusammenhang mit dem Migrationsbug (Karte 72E982B5): `docs/handoffs/Entsperren-Bug.md`.
## Lokaler Image-Build mit Smoke-Test (12.11.2026, Worktree-Branch `worktree-agent-ac9baf57a27350ff6`, lokal committet, ungemergt)

- `scripts/docker-build.sh` baut `form-backend:<Commit>[-dirty]` + `:latest` (native Architektur, PWA bei Bedarf) und prüft das Image gegen echte Wegwerf-MariaDB: migrate, serve, `/healthz`, `/ready`, PWA-Index mit CSP, Kernpfad ohne Browser (Passkey-Login per echter WebAuthn-Assertion, Kunde, Kundenschlüssel, Formular, Release, SDK-Zugang, signierte Einsendung über die öffentliche Route, DB: Zeilen in `submissions`/`stored_objects`, kein Klartext im DB-Dump, Idempotenz). Aufräumen per `trap`; alte `form-backend:<hash>`-Tags bis auf die neuesten 3. Kein Push, kein Deploy.
- DoD ergänzt (`docs/ENTWICKLUNG.md`, `AGENTS.md`): Image bauen, Smoke-Test, `IMAGE_TAG` in `post_progress`. Selbsttest: `scripts/test-docker-build.sh`. Übergabe: `docs/handoffs/Docker-Build.md`.
- Grenze: Konto und Passkey werden per SQL angelegt; browserseitige Schlüsseleinrichtung (PRF, Wiederherstellungscode, Datenschlüssel-Zugriff), Entschlüsselung, Mail und nginx/TLS sind nicht Teil des Smoke-Tests.

## UI-Feinschliff: Note anheben (11.11.2026, Worktree-Branch `worktree-agent-aaf0eabd4286f8414`, lokal committet, main eingemergt, ungemergt in main)

- Zwei Runden: Screenshots/Menüs, zwei Bewertungen, Fixes (KPI-Leerfläche, Passkey-Zeile, Palette-Touch, Formularseite mobil, Auffälligkeiten einklappbar, Suche mobil, Rechte-Chips, Mail breiter, Bereinigen-Warnstil, Disabled-Rahmen, Quellen-Chip, StepNav-Footer). Unabhängige Zweitbewertung (Skala 1-5, 5 = best): Gesamt 4,0; Ziel 4,7 nicht erreicht, Restliste in `docs/ux/feinschliff.md`, Übergabe `docs/handoffs/UI-Note.md`.
- Geprüft: Vitest 451, svelte-check 0, eslint/prettier sauber; Playwright 215 bestanden / 13 übersprungen (Opt-in-Screenshots), neue `ui-feinschliff.spec.ts` (320 px, axe hell/dunkel).

## Setup-Assistent: weitere Schritte (11.11.2026, Worktree-Branch `worktree-agent-a8ec6c629423d022b`, lokal committet, ungemergt)

- Neue optionale Schritte `passkeys` (Fakt: `GET /me/passkeys` >= 2), `token` (Fakt: `GET /account/tokens`, mindestens ein weder widerrufener noch abgelaufener Token; SDK-Zugangsdaten sind nur erzeugbar, nicht lesbar und zählen nicht, Hinweis auf das PHP-SDK im Text) und `testEntry` (Fakt: Einsendung in einem veröffentlichten Formular über `GET .../entries`; ohne veröffentlichtes Formular offen mit Hinweis; Listenfehler ohne Beleg = Fehler). Kein Backend-, Vertrags- oder Migrationsänderung.
- Reihenfolge: Konto, Wiederherstellung, Passkeys, Adressen, Mail, Kunde, Formular, Token, Probe-Einsendung, Umstieg. Schritt-IDs und gespeicherte „Später“-Werte (`setup.skipped.<id>`) unverändert gültig.
- Abschluss: Zusammenfassung mit Zahl erledigter Schritte und Links zu den übersprungenen. Setup-Leiste (`stepScope`) kennt die neuen Schritte. Code: `pwa/src/lib/onboarding*.ts`, `pwa/src/routes/admin/Installation.svelte`.
- Geprüft: vitest 442, svelte-check 0, eslint, prettier sauber, Playwright 198 bestanden / 9 übersprungen (neu 7 in `e2e/setup-flow.spec.ts` inkl. 320 px, axe hell/dunkel, Screenshots). Übergabe: `docs/handoffs/Setup-Assistent-Schritte.md`.

## Import-Generalprobe (11.11.2026, Worktree-Branch `worktree-agent-af371e818a5d86ff4`, lokal committet, ungemergt)

- Erstmals gegen das echte Altschema (`backend/Tests/FormMigrationTests/Fixtures/legacy-real.sql`, Baseline plus Migrationen 001-040 des Altsystems) mit synthetischen, realistischen Daten (echte :2-Pakete, hpke und sym, zwei Schlüsselgenerationen, Umlaute/Emoji/NULL/leer, 3-MB-Anhang, defekte Pakete) über die echten Admin-Routen: Quellprüfung, Plan aus gemeinsamer Golden-Datei (`contracts/migration/rehearsal-golden.json`, Backend und PWA testen sie), Prüflauf, Import, Phasen. Belegt: Zeilenzahlen, Bytegleichheit jedes Pakets, Entschlüsselung mit dem Altschlüssel, keine Geheimnisse in Log/Job/Audit, Fortsetzen nach Fehler, Pause und Absturz mitten im Lauf, Wiederholung/Delta ohne Duplikate.
- Echte Fehler gefunden und behoben: (1) Zellen über 1 MB (Altsystem erlaubt Uploads bis 20 MB) gingen still verloren (HEX-JSON über `max_allowed_packet` ergibt NULL); (2) `sentServer` machte jede Einsendung zum Prüffall, jetzt wird die Mailserver-ID nach `legacy_sent_server` übernommen; (3) Bericht verlor nach einer Wiederholung die offenen Prüffälle und konnte doppelte Codes enthalten.
- Sicherheitsreview B1/B2/B6 (Quellprüfung): TLS-Vorabprüfung der Server-Begrüßung vor jedem Zugangsdatum, benannte Fehlerursachen (Anmeldung, nicht erreichbar, Datenbank, Rechte, kein TLS), eine einheitliche Meldung für nicht freigegeben und nicht auflösbar, höchstens eine Quellprüfung je Konto und zwei insgesamt (429), Fehlschläge auditiert ohne Geheimnisse.
- PWA: lesbarer Prüfbericht statt Rohschlüsseln, Hinweis auf Statistikzeilen ohne Schlüssel, Fehlermeldungen der Quelle. E2E `pwa/e2e/migration-rehearsal.spec.ts` (Gesamtablauf, Fehlerfälle, 320 px, axe).
- Geprüft: Swift-Gesamtlauf gegen Wegwerf-MariaDB 466 Tests, 5 übersprungen, 0 Fehler; `validate.py` grün; vitest 438, svelte-check 0, eslint/prettier sauber, Playwright 202 bestanden/9 übersprungen. Unabhängiges Review steht aus.
- Messwert: 12 009 Einsendungen: Prüflauf 380 s, Import 352 s (34 Zeilen/s, linear; 50 000 etwa 25 min je Phase), Speicher 91 auf 283 MB, kein Pool-Deadlock. Betriebsablauf: `docs/UMSTIEG-CHECKLISTE.md`. Übergabe: `docs/handoffs/Import-Generalprobe.md`.

## Umstieg: Plan automatisch aus der Quellprüfung (11.11.2026, Worktree-Branch `worktree-agent-a0c0903c0d8bc9dce`, lokal committet, ungemergt)

- ADR 0040. Ursache des Abbruchs `unknownKeyGeneration@kid` in Phase `anfragen`: Die PWA hat `keyCustomers` und `keyGenerationNumbers` nie gefüllt.
- Backend: `POST /migration/test` liefert zusätzlich die Schlüssel (kid, Status, erstelltAm, Public-Key-Prüfung), die kid-Nutzung der Einsendungen mit Zählern (begrenzt, `complete=false` bei Überschreitung) sowie Formular- und Verbindungsnamen. Keine Geheimnisse, keine Public-Key-Bytes. Code: `FormMigration/KeyInventory.swift`, `SetupMigrationRoutes.swift`. Vertrag: `p5-implementiert.openapi.yaml`.
- PWA: Formulare, Kunden-UUID, Namespace (`legacy-<db>`), Schema/Snapshot, Verbindungen, Schlüssel und lückenlose Generationen werden automatisch gefüllt; nur der Kundenname ist Eingabe. Bei mehreren Kunden gibt es Auswahlfelder mit Vorbelegung. Warnung bei kids ohne Altbestand. Am Ende steht eine Zusammenfassung; der Start ist erst bei vollständigem Plan möglich. Das JSON unter „Erweitert“ bleibt als Überschreibung.
- Importer unverändert: Eine fehlende Generation bricht weiterhin den Lauf ab (Begründung in ADR 0040).
- Geprüft: Swift-Gesamtlauf gegen Wegwerf-MariaDB 456 Tests, 5 übersprungen, 0 Fehler (neu: `SetupMigrationKeyTests` 3/3); `validate.py` grün; svelte-check 0, eslint und prettier sauber, vitest 436, Playwright 191 bestanden / 9 übersprungen (Screenshots). Nicht mit echter Quelle geprüft; unabhängiges Review steht aus.

## DB-Pool-Deadlock bei Umstieg und Hintergrunddiensten (11.11.2026, Worktree-Branch `worktree-agent-aa30f66e51e219486`, lokal committet, ungemergt)

- Belegt in `backend/Tests/FormAdminTests/MigrationPoolTests.swift`: Bei 4 Verbindungen je Event-Loop blockierten sich die Lock-haltenden Dienste (Mail, Auth, Flow, Webhooks) und der Umstiegsjob gegenseitig. Alle bekamen nach 10 s `ConnectionPoolTimeoutError`, wie im Produktionslog. Der Job hielt 3 Verbindungen gleichzeitig und scheiterte mit 2 je Loop selbst (`migration_failed`).
- Behoben: Der Importer nutzt die Verbindung des Job-Locks (Spitzenwert 2 statt 3), und der Pool richtet sich nach der Zahl der Loops: `max(4, 32 / Loops)`. Keine ENV-, Vertrags- oder Migrationsänderung, Importsemantik unverändert.
- Übergabe mit Messwerten, Restrisiken und Prüfbefehlen für den Betrieb: `docs/handoffs/DB-Pool-Deadlock.md`.

## Umstieg: Alt-Kundenschlüssel im Browser übernehmen (11.11.2026, Worktree-Branch `worktree-agent-ada0129e51f86cd2e`, lokal committet, ungemergt)

- ADR 0037. PWA: Konto → Sicherheit → Erweitert, je Kunde „Altschlüssel aus dem Umstieg übernehmen“ (`/account?legacy=1`, verlinkt aus Umstieg „Prüfung“/„Umschaltung“ und der Sperrmeldung der Einsendungen). Alter privater X25519-Schlüssel wird lokal gegen kid + Public Key der importierten Generation geprüft und per HPKE an den eigenen Kontoschlüssel versiegelt; Upload nur der Hülle über den vorhandenen Selbstzugang (`PUT key-access/{eigeneId}`: key.manage, frische Anmeldung, CSRF, Audit `key.access.repair`). Kein neuer Endpunkt.
- Importer: alte Recovery-Hülle `datenschluesselRecovery` (formatgleich, Vergleich in ADR 0037) wird bytegleich nach `data_key_recovery` übernommen; danach wirkt der alte Recovery-Code über „Mit Recovery-Code öffnen“.
- Geprüft: Swift gegen Wegwerf-MariaDB (gezielt und Gesamtlauf, siehe `docs/handoffs/Altschluessel-Uebernahme.md`), svelte-check 0, eslint, prettier, vitest, Playwright 180 bestanden/9 übersprungen, `contracts/auth/validate.py` grün. Nicht mit echtem Altschlüssel geprüft; unabhängiges Review steht aus.

## Darstellungsoptionen im Konto (11.11.2026, Worktree-Branch `worktree-agent-a0cc94f17870fdab5`, lokal committet, ungemergt)

- Backend: `GET/PUT /admin/api/v1/me/preferences` (`backend/Sources/FormAdmin/AccountPreferenceRoutes.swift`) auf der vorhandenen Tabelle `account_preferences`, keine Migration. Nur eigenes Konto, PUT mit Origin/CSRF, keine frische Anmeldung, kein Audit. Allowlist `theme` light/dark/system, `accent` = 20 IDs aus `pwa/src/lib/accents.ts`, `glow` 0–6; sonst 422 „Ungültige Darstellungsoption.“ Vertrag: `contracts/auth/p5-implementiert.openapi.yaml`. Neue Akzentfarben müssen in beiden Allowlists ergänzt werden.
- PWA: `lib/appearance.ts` (Regeln), `lib/appearanceSync.svelte.ts` (Laden nach Anmeldung, Konto gewinnt; leeres Konto übernimmt den Browserwert nur, wenn er diesem Konto oder niemandem gehört; Cache-Besitzer `appearance-account`, nicht gesendete Änderung `appearance-dirty`; Speichern entprellt 600 ms, Fehlerhinweis im Menü, Wiederholung nach 30 s). localStorage bleibt Cache für ersten Paint und Login/Setup.
- Geprüft: Swift `AccountPreferenceTests` 3/3 gegen Wegwerf-MariaDB; svelte-check 0, eslint, prettier, vitest 373, Playwright 178 bestanden/9 übersprungen. `contracts/auth/validate.py` scheitert bereits vorher an der Rechte-Katalog-Prüfung (Zeile 233, unabhängig von dieser Änderung).
- Übergabe: `docs/handoffs/Darstellung-im-Konto.md`.

## PWA-Oberfläche: Stand 11.11.2026 (maßgeblich)

- Alle unten aufgeführten PWA-Durchgänge (Bereichsauswahl, Fable-Struktur, Einrichtungsfluss, UI-Durchgänge 1–5, PRF-Hinweis, Verbindungen-Fix) sind in `main` gemergt und im öffentlichen Repo (`dba3dd0`). Die Zusätze „Worktree-Branch … ungemergt“ in den folgenden Abschnitten sind überholt.
- UI-Bewertung durch einen unabhängigen Bewerter anhand von Screenshots (Mock-Daten): 3,2 → 3,5 → 3,8 → 4,2 → 4,4 → **4,5/5** (alle 21 Seiten 4,5). Ziel des Nutzers erreicht.
- Prüfstand: svelte-check 0 Fehler, eslint/prettier sauber, vitest 327, Playwright 168 bestanden (9 übersprungen).
- Nicht gegen das echte Backend/den echten Browser geprüft: „Passkey hinzufügen“, Kunden-Spalte der Konten, „Mitglied hinzufügen“, Passkey-Direktabfrage bei frischer Anmeldung (Safari verlangt evtl. eine Geste), PRF-Hinweis in Firefox/macOS.
- Offene Restpunkte (bewusst nicht gebaut): Greifmodus/zweispaltiger Feldeditor, Tabellenregeln (Sortierung/URL), gemeinsame Massenleiste, gemeinsamer Entsperr-/Sitzungsablauf-Dialog, Fokus nach Alt+Pfeil auf Felder mobil, Restmängel aus `shots-review6/BEWERTUNG.md` (Einstellungen: Alarm-Verbindung als Auswahl; Formular: Checklisten-Begriffe; Mein Konto: Aktionen im Kartenkopf).
- Konzeptentwürfe (Fable 5.2 bevorzugt, weitere Modelle) liegen unter `docs/ux/konzepte/` (nur privates Repo).
- Nächster Schritt: Image `latest` aktualisieren (`git pull` im Deploy-Branch, `bash deploy/compose/update.sh`, Browser hart neu laden) und Oberfläche im echten Betrieb abnehmen.

## Passkey-Bestätigung auf der Seite (Step-up, ADR 0037) (11.11.2026, Worktree-Branch `worktree-agent-abe0a58be23a139d1`, lokal committet, ungemergt)

- Nutzerwunsch: keine erneute Anmeldung für sensible Aktionen. Backend `POST /auth/reauth/{options,verify}` setzt nur `authenticated_at` der eigenen Sitzung (UV-Passkey desselben Kontos, Challenge `fresh-auth`, einmalig, CSRF, Drosselung, Audit `auth.reauth`); mit Zweitfaktor-Policy 409 `second_factor_required` → PWA fällt auf den vollen Login zurück. `GET /migration/jobs` und `GET /settings` ohne Frische lesbar.
- PWA: zentraler `ReauthDialog` (Controller `lib/admin/stepup.svelte.ts`, eingehängt in `guard.svelte.ts`/`App.svelte`), ein Vorgang für parallele Anfragen, nach Abbruch erst bei Nutzeraktion wieder.
- Commits 20b3dee (Backend, Vertrag, ADR), 5fcf2f3 (PWA). Geprüft: komplette Swift-Suite gegen echte MariaDB (Container `dbg-reauth-mariadb`, entfernt) 439 Tests, 0 Fehler, 5 übersprungen, inkl. 7 neue `ReauthHTTPTests`; PWA svelte-check 0, eslint/prettier, vitest 377, Playwright 177 grün (9 übersprungen). `contracts/auth/validate.py` scheitert bereits vorher (Rechtekatalog `migration.run`/`system.settings` fehlt im Entwurfs-Enum), unabhängig von dieser Änderung.
- Offen: echter Browser/Authenticator (Safari-Geste, Passkey-Auswahl mit allowCredentials), unabhängiges Sicherheitsreview. Übergabe: `docs/handoffs/Passkey-Step-up.md`.

## PWA: HTML-E-Mail-Builder im Mail-Reiter (11.11.2026, Worktree-Branch `worktree-agent-aafdd4bb248d0ad0a`, lokal committet, ungemergt)

- Design (MJML-Bausteine, `mjml-browser` 4.18.0 nachgeladen), Einfach (eigener Rich-Text-Editor), Quelltext; Speicherformat wie Altsystem (`<!--kubus-mail-quelle:…-->`), keine Backend-/Vertragsänderung. Entscheidung: `docs/decisions/0037-html-mail-builder.md`, Übergabe: `docs/handoffs/Mail-Builder.md`.
- Geprüft: svelte-check 0, eslint, prettier, vitest 383, Playwright 182 bestanden/9 übersprungen (7 neu inkl. echter CSP, axe, 320 px hell/dunkel).
- Offen: Review, Merge, Testversand an Outlook/Gmail; Bild-Upload und Vorlagenbibliothek bewusst nicht gebaut.

## PWA: UI-Bewertung fünfter Durchgang 4,4/5, Umsetzung (11.11.2026, Worktree-Branch `worktree-agent-a6d1e84b67f09cce1`, lokal committet, ungemergt)

Commits 183fdb9, 6681c1f, 0a2a298, 5aa31ba, 34682f4 (Speicherstatus, Formular-Diagramm, Widersprüche, Mail, Felder mobil/Seitenkopf). Echte Fehler und Mock-Artefakte: docs/handoffs/UI-Durchgang-5.md. Geprüft: svelte-check 0, eslint, prettier, vitest 327, Playwright 168 grün. Erneute Bewertung steht aus.

## PWA: UI-Bewertung vierter Durchgang 4,2/5, Umsetzung (11.11.2026, Worktree-Branch `worktree-agent-a97092d048db46028`, lokal committet, ungemergt)

Commits 29fd1dd, 1e1d8d0, fb2808b, 509b9b1, 6249293. Übergabe mit echten Fehlern, Mock-Artefakten und nicht umgesetzten Punkten: docs/handoffs/UI-Durchgang-4.md. Geprüft: svelte-check 0, eslint, prettier, vitest 317, Playwright 167 grün. Erneute Bewertung steht aus.

## PWA: UI-Bewertung dritter Durchgang 3,8/5, Umsetzung (10.11.2026, Worktree-Branch `worktree-agent-a38f11d123f49c66e`, lokal committet, ungemergt)

Commits 78476e9 (Datumsformate, CardHeader, Seitenraster, KPI, Betrieb), 1414032 (Einstellungen, Verbindungen, Konten, Mitglieder), 6f9dd5f (Speichermuster, Textdiät, Tokens-Dialog, Stepper, Scroll-Hinweis) und Folgecommit. Übergabe: docs/handoffs/UI-Durchgang-3.md.

- Neu: `lib/format.ts` (ein deutscher Formatierer, nie „undefined“/„Invalid Date“), `CardHeader`, `RichText`, `scrollHint`, Route `/accounts` (System > Konten), Seitenbreite einheitlich über den Shell-Container.
- Geprüft: svelte-check 0, eslint, prettier, vitest 297, Playwright vollständig grün (167, 9 übersprungen). Erneute Bewertung steht aus.
- Grenzen: „Mitglied hinzufügen“ setzt Leserecht über den bestehenden Rechte-Endpunkt (nicht gegen echtes Backend geprüft). Verbindungen zeigen „getestet“ nur für die laufende Sitzung (API liefert keinen Teststatus); Bearbeiten/Löschen fehlen mangels API. „Passkey hinzufügen“ im Konto bewusst nicht (Passkey-Logik gehört einem anderen Agent).

## PWA: Geführter Einrichtungsfluss (10.11.2026, Worktree-Branch `worktree-agent-aaf780feb413b194c`, lokal committet, ungemergt)

- `/installation` ist eine Checkliste mit sieben echten Schritten (Konto/Passkey, Wiederherstellungscode, Mail-Versandweg, Adressen, Kunde, Formular veröffentlichen, optional Umstieg; Umstieg nur mit Recht und aktivem Umstieg). Status kommt aus den Daten (`lib/onboarding.ts` rein, `lib/onboarding.svelte.ts` Store/Laden); unbekannt = Fehler, nie geraten. Kunde, Formular und Wiederherstellungscode werden inline erledigt. Optionales lässt sich „Später“ (nur dieser Browser, localStorage je Konto) verschieben. Abschluss setzt `setup.completed=true` über den bestehenden Settings-Vertrag (frische Anmeldung nötig); `setup.step` wird nicht mehr geschrieben.
- Kontext: Wechselt ein Schritt auf eine andere Seite, merkt sich sessionStorage den Schritt (überlebt Neuladen); `SetupBar` (Shell) zeigt dort „Einrichtung · Schritt n von m“, „Zurück zur Einrichtung“ und nach echter Erledigung „Weiter zum nächsten Schritt“. Die Leiste prüft den Schritt alle 5 s, bei Fokus und kurz nach Klick/Absenden; sie endet beim Verlassen der Seiten des Schritts. Seitenleiste: „Einrichtung fortsetzen (n von m)“ oben im Bereich bis zum Abschluss. Startseite (`/overview`, `/t`) leitet bei offener Einrichtung einmal (ohne Verlaufseintrag) dorthin; Deep Links nicht mehr.
- Geprüft: svelte-check 0, eslint, prettier, vitest 241, Playwright 155 bestanden/9 übersprungen (neu `e2e/setup-flow.spec.ts`: Durchlauf mit Hin-/Rückweg über Verbindungen, Einstellungen, Formularseite, Neuladen, 320 px, axe hell/dunkel).
- Grenzen: „Mail getestet“ ist serverseitig nicht erfasst; erledigt = aktive Verbindung vorhanden. Formulare/Kunden nur für die ersten 10 Kunden geprüft. „Später“ gilt je Browser.

## PWA: UI-Bewertung, offene Punkte umgesetzt (10.11.2026, Worktree-Branch `worktree-agent-a007d9c4b0448dfe0`, lokal committet, ungemergt)

- Umstieg (`Migration.svelte`, `lib/admin/migrationFlow.ts`, `StepNav`): fünf Schritte mit je einem Panel, Weiter/Zurück, Fortschritt aus echten Läufen (laufender Import und Prüfung springen selbst weiter), Prüfwerte (Schema-HMAC, Formular-UUIDs, Snapshot-Hash, Kunden-UUID) aus der Quellprüfung übernommen und unter „Erweitert“, Prüfbericht als Zeilenliste, Lade-/Leer-/Fehlerzustände je Schritt. Verträge und Endpunkte unverändert.
- Einsendungen: deutsche Datumsfelder (`DateField` mit Maske und Kalenderwahl, intern ISO) statt ISO-Freitext, Zeilenaktionen im „⋯“-Menü (`RowMenu`, bits-ui), Kartenliste mobil, ein Hinweis zum gesperrten Zugriff (Hinweis je Einsendung nur bei entsperrtem Schlüsselbund). Fehler behoben: `DateField` verlor Eingaben (Effekt überschrieb Text vor dem Commit).
- Mobiler Formularkopf (kompakte Aktionen in einer Zeile, Reiter mit Überlaufpfeilen), Seitenleiste bei 800 px Höhe ohne abgeschnittenen Umstieg, Einbindung mit PHP-SDK-Kurzanleitung (Inhalt aus `sdk/php/README.md`), Unit-Tests für SaveBar, SearchField, ScopePicker, formStatus, rights, delta, NewAccountPanel.
- Geprüft: svelte-check 0, eslint, prettier, vitest 280, Playwright vollständig grün. Erneute Bewertung steht aus. Grenzen: „Weiter“ im Umstieg folgt nur der Datenlage; PHP-Beispiel nennt die Backend-Adresse als Platzhalter.

## PWA: UI-Bewertung 3,2/5, Umsetzung (10.11.2026, Worktree-Branch `worktree-agent-aa1049713be59fd43`, lokal committet, ungemergt)

Grundlage: Bewertung der 21 Seiten (Screenshots, Bericht liegt außerhalb des Repos). Ziel des Nutzers: erneute Bewertung mindestens 4,5/5. Umgesetzt in drei Gruppen (Commits 2f50642, 7bbb856, ac81733 und Folgecommit):

- Gruppe 1: einheitliche Formularstatus (`lib/admin/formStatus.ts`: Entwurf/Live/Pausiert), Rechte als Klartext (`lib/admin/rights.ts`), Seitenleiste markiert Kunden bei Formularliste, Breadcrumb ohne Doppelglieder und mit Zurückpfeil mobil, „Betrieb“ bleibt aktiv, Gruppen „Ansicht für“/„Arbeiten“, Aufbewahrung als echter Reiter (`RetentionPanel`, Switch + Tage + Sticky-`SaveBar`), Reiter Ablauf entfernt (`/flow` öffnet die Übersicht), Diagramm mit Mustern und Markern, einheitliche KPI-Kachel, Kontraste für Checkbox/Switch/deaktivierte Schaltflächen, dunkle Kartenebene, Alert-Rahmen als Inset-Ring, `SearchField`, klickbare Tabellenzeilen mit Chevron und Unterzeile mobil.
- Gruppe 2: Mitglieder (Klartext-Rechte mit Beschreibung, Leerzustand), „Neues Konto“ in Mitglieder verschoben (`NewAccountPanel`), Konto flach mit „Erweitert öffnen“, Einstellungen mit Sticky-`SaveBar` und Klartext-Untertitel, Verbindungen mit Leerzustand und Anlegen auf Abruf, Betrieb mit Alarmkarte, Filterkarte und Leerzuständen.
- Gruppe 3: Mail (Karten, Switches, Platzhalter-Chips, Sticky-Speicherleiste, Zustellungen eigene Karte), Felder (Icon-Reihenfolge, Hinweise einklappbar), Missbrauchsschutz gekürzt, Veröffentlichen mit Prüfstatus, Webhooks Liste zuerst, „API & MCP“ mit Kunden-/Formularauswahl statt UUID-Eingabe.
- Prüfungen: svelte-check, eslint, prettier, vitest (233) und Playwright (151, 9 übersprungen) grün.
- Offen (bewusst nicht umgesetzt): Umstieg als echter Schritt-für-Schritt-Stepper mit automatisch übernommenen Prüfwerten, Einsendungen (Datumsauswahl im deutschen Format, Überlaufmenü für Zeilenaktionen, Kartenliste mobil), mobiler Formularkopf mit Überlaufmenü, Tabellen als Kartenlisten für Einsendungen, Einbindung mit PHP-SDK-Kurzanleitung, Einrichtungsmeldung unterscheiden (gehört zur parallelen Einrichtungsarbeit). Erneute Bewertung steht aus.

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

| Teil                | Datei                    | Status                                                                                                                                                                                                                                               |
| ------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A Routen/Handler    | `A-routen-handler.md`    | erstellt, ungeprüft (nur Agent-Bericht, keine Stichprobe)                                                                                                                                                                                            |
| B Funktionen/Felder | `B-funktionen-felder.md` | NICHT erstellt; Sonnet-Agent und Codex-Delegation (gpt-6.1-sol) wurden vom Auto-Mode-Classifier abgelehnt (Data Exfiltration: Altprojekt liegt außerhalb des Arbeitsverzeichnisses, Codex sendet Code an externen Dienst). Wartet auf Nutzerfreigabe |
| C Daten/Migration   | `C-daten-migration.md`   | erstellt durch Koordination (26.10.2026) aus Schema/Migrationen; nur Spaltenebene, `migrate.php`/`verify.php` nicht gelesen; ungeprüft                                                                                                               |
| D Krypto/Protokolle | `D-krypto-protokolle.md` | erstellt, ungeprüft                                                                                                                                                                                                                                  |

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
Review P5 Rest (01.11.2026, Claude reviewer, statisch + run-tests/npm test; `docs/paritaet/review-p5-rest.md`): keine hohen Befunde (Passkey/CBOR/DER, Einmal-Token, Bootstrap, SSRF-HostGuard, Header-Injection, Entwurfs-If-Match, Static-Site/CSP, SW-Allowlist ohne Befund). Behoben vom Koordinator mit Tests: M1 (alle X-Forwarded-For-Zeilen zusammenführen, `ForwardedForTests`), M2 (STARTTLS-Barriere gegen eingeschleusten Klartext; Test belegt: ohne Barriere lief die Sitzung mit gefälschtem „250“ weiter, mit Barriere bricht sie ab), M3 (Mail-Lease wird beim Sendestart erneuert; Zeile nicht mehr `leased` → nicht senden), `encodeURIComponent` im Chiffrat-Pfad. `integration-test.sh` 195 Tests: 4 Läufe 0 Fehler, 1 früherer Lauf mit 1 nicht identifiziertem Fehler (nicht reproduzierbar; SMTP-Suite 8× stabil). Offen (niedrig): IP-Literal als SMTP-Host (geprüft und getestet 11.11.2026, siehe SMTP-TLS-Härtung oben), `$` in Regexen lässt `\n` zu, freie Absenderadresse, Bestätigungsmail-Relay, Argon2/bcrypt blockieren Pool-Thread, Passkey-Limit nur in `begin`, Entwurfs-Obergrenze, Steuerzeichen im ACODE, Content-Type sw.js/manifest ungeprüft, 6to4/Teredo im HostGuard.
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
Grenzen und Fortsetzung in `docs/handoffs/Missbrauchsschutz.md`, Entscheidung ADR 0026. Kein Commit, Deployment oder produktive Migration. DB-Tests geschrieben,
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
- **Proxy-Betriebshärtung (11.11.2026, Todolino 2000434E):** Vorlage mit HSTS/Header, IP-gekürztem Log, logrotate 7 Tage, `check-headers.sh` und lokalem nginx-Container-Test (grün); BETRIEB.md zu internem Listener/Zweitfaktor ergänzt. Details `docs/handoffs/Proxy-Haertung.md`. Nicht gepusht/deployt.

- **Review Astra 2, Rest (12.11.2026, Todolino A5EC4A54, Branch `agent/astra2-reste`, Worktree `~/Development/worktrees/fb-astra2`, nicht gemergt):** M1, M2, M5, M6, L1 umgesetzt (ADR 0042). `integration-test.sh` (FormAdmin/Ingest/Deploy) 266 Tests: 264 grün, 2 übersprungen (SFTP ohne Docker-Server); die zwei zunächst roten SDKDeployTests nach Korrektur einzeln 3/3 grün. Schema: 5 Spalten in `sdk_targets`, Upgrade 0033 ungeprüfter Bestandskandidat. Grenzen: `maxConcurrent` ohne Umgebungsvariable, Kontoerkennung nur Host+Benutzer, kein Lasttest (P10), kein SFTP-/Proxy-Differential. Automatische SDK-Updates nach Review und Merge freigebbar.

> **Hinweis zum öffentlichen Export:** Verweise auf `docs/paritaet/` (Analyse des Altsystems), `docs/handoffs/` (interne Übergaben) und `.claude/agents/` zeigen auf Material, das in dieser Veröffentlichung bewusst fehlt. Maßgeblich sind README, `docs/BETRIEB.md`, `docs/decisions/` (ADR) und `contracts/`.
