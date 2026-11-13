# Sicherheitsreview: Passkey-Step-up, Altschlüssel-Übernahme, Quellprüfung

11.11.2026, unabhängiges lesendes Review (Stand `main` 2bb843a). SPDX-License-Identifier: AGPL-3.0-only.
Gegenstand: ADR 0037 (Step-up), ADR 0038 (Altschlüssel), ADR 0040 (`POST /migration/test`, `KeyInventory.swift`).

## Befunde

### B1 (mittel): `tls: "verify"` erzwingt kein TLS (stiller Downgrade auf Klartext)

- Stelle: `backend/Sources/FormAdmin/MigrationService.swift` `withSource` (MySQLConfiguration mit Standard-TLS, nur `disable` setzt nil); Ursache in `mysql-nio` 1.9.2 `Sources/MySQLNIO/MySQLConnectionHandler.swift:117-141`: TLS wird nur gestartet, wenn der Server `CLIENT_SSL` meldet, sonst läuft die Verbindung im Klartext weiter.
- Szenario: Quelle ohne TLS oder ein Angreifer auf dem Pfad (Quellnetz laut `migration.allowedNets`) entfernt `CLIENT_SSL` aus der Begrüßung. Die UI und die API sagen weiter `verify`. Zugangsdaten (Benutzername im Klartext, Passwort je nach Plugin als Scramble oder per RSA-Austausch), `SHOW GRANTS`, Namen, Schlüsselmetadaten und beim echten Lauf alle Altdaten laufen unverschlüsselt und unauthentisiert (Manipulation der Quelldaten möglich).
- Beleg (ausgeführt, nicht eingecheckt): Fake-Server, der `CLIENT_SSL` nicht anbietet, plus Client mit derselben Konfigurationsform wie `withSource` (`MySQLConnectionSource`, `tlsConfiguration` Standard). Ergebnis: Client sendete 94 Byte, kein TLS-ClientHello, Benutzername `srcuser` im Klartext. Hinweis: Das war ein Client-Probe-Test, nicht der Endpunkt selbst (keine DB in dieser Umgebung).
- Vorschlag: Nach dem Verbinden `SHOW SESSION STATUS LIKE 'Ssl_cipher'` prüfen und bei leerem Wert abbrechen, solange `tls == "verify"`. Besser vorher: eigene Handshake-Prüfung. Test: Fake-Server ohne `CLIENT_SSL` muss mit 422 scheitern, bevor Zugangsdaten gesendet werden (Passwort-Scramble wird bereits in der Handshake-Antwort gesendet; der Abbruch nach Statusabfrage verhindert das nicht. Echte Abhilfe: vor dem Auth-Paket abbrechen, z. B. Fork/Option in mysql-nio oder Vorab-Probe der Begrüßung auf `CLIENT_SSL`).
- Schweregrad: mittel (Voraussetzung: Netzwerkposition oder TLS-lose Quelle; Allowlist begrenzt auf interne Netze).

### B2 (niedrig): Auflösungs-Orakel in der Quellprüfung

- Stelle: `MigrationService.swift` `withSource`: `blocked` liefert „Quelladresse nicht freigegeben…“, jeder andere Auflösungsfehler „Quelle konnte nicht aufgelöst werden“.
- Szenario: Konto mit `migration.run` und frischer Anmeldung kann bei gesetzter `migration.allowedNets` Hostnamen auf Existenz und Zugehörigkeit zu Netzen prüfen (interne DNS-Enumeration). Verbindungsfehler selbst sind einheitlich (gut).
- Vorschlag: eine gemeinsame Meldung für beide Fälle, Details nur im Server-Log. Prüffall: unbekannter Host und Host außerhalb der Allowlist liefern identischen Text.

### B3 (niedrig): Importierte Alt-Recovery-Hüllen sind für jedes `key.manage`-Konto abrufbar (Offline-Angriff)

- Stelle: `KeyManagementRoutes.swift:221-238` (`GET key-recovery`: Recht `key.manage`, frisch, auditiert), `FormMigration/Transform.swift:42-58` (bytegleiche Übernahme).
- Szenario: Die Stärke hängt am Alt-Code (PBKDF2 600000, Alt-Mindestlänge 24, ggf. vom Nutzer gewählt). Ein Konto mit `key.manage`, aber ohne eigenen Zugang, lädt die Hülle (nur der Abruf ist auditiert) und rät offline. Das Muster gilt auch für neue Hüllen, wird durch den Import aber auf Codes unbekannter Entropie ausgedehnt.
- Vorschlag: In ADR 0038 als Restrisiko ergänzen und nach Übernahme Rotation (neue Generation, neue Recovery) empfehlen bzw. in der UI erzwingen. Kein Codefehler.

### B4 (niedrig): Dokumentation weicht vom Code ab (Frischefenster)

- ADR 0037 „Das Frischefenster bleibt 5 min (`AuthGuard.freshness`)“. Tatsächlich: `SessionService.freshWindow()` Standard 30 min (Einstellung `auth.freshLoginMinutes`, bis 120), Rückfall 300 s. `AuthGuard.freshness` existiert nicht; `ReleaseRoutes.freshness` (300 s) gilt nur für Veröffentlichungsbestätigungen (`ReleaseRoutes.swift:17, 228-231`).
- Auswirkung: Mit Step-up (kostenlos wiederholbar) ist das Sicherheitsversprechen „5 Minuten“ aus dem ADR nicht das tatsächliche (30 min). Außerdem erneuert der Step-up `authenticated_at`, das die Veröffentlichungsbestätigung bindet; das ist beabsichtigt, aber im ADR nur indirekt beschrieben.
- Vorschlag: ADR korrigieren.

### B5 (niedrig, Hinweis): Step-up ist nicht an die auslösende Aktion gebunden

- Stelle: `LoginService.finishReauth`, `pwa/src/lib/admin/stepup.svelte.ts`, `ReauthDialog.svelte`.
- Szenario: Der Dialog nennt keine Aktion. Eine Bestätigung gilt danach für alle frischepflichtigen Aktionen des Fensters (bis 30 min). Das ist die vom Nutzer gewünschte Semantik; ein Angreifer mit Skriptausführung im PWA-Kontext braucht trotzdem eine Nutzergeste und UV-Passkey, kann aber ein vom Nutzer ausgelöstes Dialogfenster mitnutzen. Fenster-Nutzung ist durch CSRF/Origin nicht ausgeschlossen.
- Vorschlag: Falls gewünscht, bei besonders sensiblen Aktionen (Entzug, Schlüssel) kürzeres `maxAge` an `requireFreshAuthentication` übergeben.

### B6 (niedrig, Hinweis): Zähler und Aufwand

- `POST /migration/test` hat nur das Standardbudget (120/min/IP). Jeder Aufruf baut eine eigene `Application`, scannt bis 200000 Zeilen/20 s und hält eine Quellverbindung. Gleichzeitige Aufrufe eines berechtigten Kontos sind nicht begrenzt (`SetupMigrationRoutes.swift` `root.post("test")`). Außerdem hat die PWA ein Timeout von 10 s (`http.ts`), die Quelle bis 20 s; der Server arbeitet dann weiter. Vorschlag: Sperre „ein Test gleichzeitig“ und größeres Timeout für diesen Aufruf.
- Fehlgeschlagene Quellprüfungen werden nicht auditiert, nur Erfolge (`migration.source.test` ohne Details). Für Portscan-Nachvollziehbarkeit Host-Hash/Port als `safe_details` erwägen (kein Passwort).

## Geprüft, ohne Befund

- Step-up Replay/Challenge-Bindung: Challenge an Sitzung, Zweck `fresh-auth` und Konto gebunden, nur Hash, 120 s, Verbrauch vor Prüfung in eigener Transaktion mit `FOR UPDATE` (`LoginService.swift:195-210`), neue Optionen widerrufen alte. Login-Challenges sind nicht verwendbar (Zweckfilter). Parallelverifikation serialisiert. Zähler atomar (`advanceCounter`).
- Fremde/unbekannte Credentials: gleicher Dummy-Pfad und Antwort `401 authentication_failed`; UV Pflicht (AssertionVerifier).
- Wirkung nur auf die eigene Sitzung: bedingtes Update unter `FOR UPDATE` auf lebende, authentifizierte Sitzung desselben Kontos, Konto aktiv, Audit in derselben Transaktion ohne Geheimnisse. Kein neuer Token.
- CSRF/Origin: beide Routen über `requireAuthenticated(mutation: true)` (kein Bearer, exakte Origin, Token im Konstantzeitvergleich `verifyCSRF`). Zweitfaktor-Listener werden mit 409 abgewiesen; `AuthRoutes` reicht `config.secondFactorRequired` an `LoginService` durch.
- Drosselung: Budget plus IP-Zähler plus Konto+IP-Sperre; gesperrt wird vor dem Verbrauch der Challenge geprüft.
- PWA: Wiederholung nur einmal und nur nach `reauthentication_required` (Server hat die Aktion dann nicht ausgeführt); `next` läuft über `safeNext`; Rückfall nur bei 409/404/401 ohne `authentication_failed`.
- Altschlüssel: Der Browser leitet den öffentlichen Schlüssel ab und vergleicht kid und 32 Byte; versiegelt wird nur an den lokal abgeleiteten Kontoschlüssel, der mit `/me/key-bundle` übereinstimmen muss. Ein bösartiger Server kann dadurch keinen fremden Zielschlüssel unterschieben. Privater Schlüssel: keine URL, kein Storage, kein `console` im Pfad, Puffer werden überschrieben. Server-Route `PUT key-access`: `key.manage` vor und in der Transaktion, frisch, CSRF, nur aktive/auslaufende Generation, fremder Zugang wird nie ersetzt.
- `POST /migration/test`: Recht `migration.run`, `migration.enabled`, CSRF, frisch, Allowlist leer = gesperrt, Adresse fest an Socket gepinnt, alle aufgelösten Adressen müssen in der Allowlist liegen, nur-lesende Grants (`readOnlyGrant`), generische Fehlermeldung. Antwort: nur kid, Status, Zeit, Gültigkeitsflag, Zähler, Formular-UUIDs/-Namen (getrimmt, 200 Zeichen), keine Public-Key-Bytes, Hüllen, Hosts oder Zugangsdaten; `Cache-Control: no-store`. `KeyInventory` liest je Spalte nur 30 Byte, Bezeichner fest, Zahlen intern, harte Grenzen.

## Lücken dieses Reviews

- Keine MariaDB in der Umgebung: die Swift-Integrationstests (u. a. `ReauthHTTPTests`) wurden nicht ausgeführt, B1 nur über einen Client-Probe-Test belegt, nicht über den Endpunkt.
- Nicht geprüft: `AssertionVerifier` (Origin/RP-ID/UV-Flag-Details), `ThrottleService`-Implementierung, Browser-Passwortmanager-Verhalten für das Feld `type=password` der Altschlüssel-Eingabe (könnte das Speichern anbieten; ungeprüft), Echtdaten/echter Altschlüssel, Timing-Seitenkanäle des Dummy-Pfads.
- PWA-Tests (vitest) und E2E nicht ausgeführt.
