# ADR 0026: Interne Einrichtung und persistente Migrationssteuerung

03.11.2026; Implementierungsentscheidung für P11-C/D. Keine Betriebs- oder Cutoverfreigabe.

## Vertrag und Gründe

`setup.completed` (Standard false), `setup.step` (0–5), `setup.mailPending`
(Standard true), `migration.enabled` (Standard true) und `migration.allowedNets`
(Standard leer, optional FORM_MIGRATION_ALLOWED_NETS) stehen in der Registry.
Booleanwerte sind exakt `true`/`false`. Änderung erfolgt über den revisionsgeschützten,
frisch authentifizierten Settingsvertrag mit `system.settings`, CSRF/Origin und
atomarem Audit nur der Schlüsselnamen. Damit ist auch das ausdrücklich beauftragte
manuelle Abschalten des Assistenten möglich. Kein Abschluss behauptet automatisch
eine erfolgreiche synthetische Datenprüfung.

Die Einrichtung fragt intern `/admin/api/v1/setup-state` ab. Ein Assistent ist nur
bei fehlendem Abschluss und explizitem `system.settings` erforderlich. Bootstrap und
Passkeyregistrierung bleiben beim bestehenden installationsgebundenen Setup-Link.
Kein First-Visitor-Bootstrap. Schritte/Texte richten sich nach UX 3.17/5.

**Abhängigkeit:** Im Checkout ist nur kundengebundene Recovery vorhanden. Der
kontoweite, einmalige P12-B-Code samt Bestandsupgrade fehlt. Deshalb blockiert der
Assistent in Schritt 2; kein Schein-Code, keine Ersatzschlüsselspeicherung und kein
vorgegebener erfolgreicher Gesamtabschluss. Das Paket ist damit noch nicht vollständig
abgenommen. Die restlichen Assistentenschritte sind im Handoff als Restarbeit benannt.

Migration erhält das explizite Systemrecht `migration.run`; es ist kein Tokenrecht.
Neue Endpunkte werden ausschließlich vor Einfrieren des internen Responders registriert:

- POST `migration/test`: Quellverbindung, SELECT 1, konservative SHOW-GRANTS-Allowlist,
  Schema-HMAC aus exakt derselben Manifestprojektion wie P9; wertfreies Mengeninventar
  und bis zu 1000 Formular-UUIDs (größere Formularkataloge derzeit ausdrücklich abgelehnt). Keine Rollen-/Schreibrechte
  oder GRANT OPTION. Die Prüfung führt keine Testschreibzugriffe aus.
- POST `migration/jobs`: `{source,plan,expectedSchema,dryRun:true}`; unveränderlicher
  JSON-Plan mit Namespace/Dump-SHA256 gemäß P9, explizite Zuordnung. Kunden können
  neu angelegt oder bei identischer UUID und identischem Namen wiederverwendet werden;
  keine Änderung vorhandener Kunden. Der Importer prüft deren Snapshot bei Wiederholung.
- GET `migration/jobs`: maximal 50 Kontrollstände/Berichte, keine Credentials, Plannamen,
  Quellschlüssel oder SQL-Diagnostik.
- POST `migration/jobs/:jobId/{pause,resume,import,remove-source}`: bedingte Übergänge
  unter Zeilensperre und mit Audit. `import` nutzt denselben gespeicherten Plan nach
  beendetem Prüflauf. `resume` bleibt dieselbe Jobkennung und derselbe P9-Ledger.

Alle Migrationsoperationen verlangen frische menschliche Cookieanmeldung und
Live-Systemrecht; Mutationen außerdem CSRF/Origin. `migration.enabled=false` sperrt
neue Kontrollen und stoppt den laufenden Import an der nächsten Objektgrenze.
Den Altzugriff daher vor dem Abschalten entfernen. Der bestehende Konverter wird
bei öffentlichem Dashboard nicht mehr registriert; sein eigener Vertrag/rechtlicher
Schutz (`system.manage`) bleibt ADR 0025.

## Geheimnisse und Netz

Host, Datenbank, Benutzer und Passwort werden getrennt als AES-GCM-Secrets gespeichert
(SecretStore-Grenze 200 Bytes je Feld); Jobzeilen enthalten nur Referenzen, Port/TLS.
Der nicht angezeigte HMAC-Betriebsschlüssel wird unter Settings-Zeilensperre genau einmal
zufällig erzeugt und ausschließlich als SecretStore-Referenz `_migration.hmac` gehalten.
Er wird nicht bei jedem Lauf abgeleitet/ersetzt. Bestehende CLI-Ledger mit anderem
FORM_MIGRATION_HMAC_KEY sind kein kompatibler Wiederaufnahmefall; keine stillen
Neunachweise. Betriebsschlüssel und Server-Hauptschlüssel müssen gesichert bleiben.

HostGuard prüft alle DNS-Antworten gegen explizite Netze. Die tatsächliche Socketadresse
wird auf eine geprüfte IP festgelegt; der ursprüngliche Host bleibt für TLS erhalten.
Standard ist vollständige Zertifikatprüfung; disable erfordert zusätzlich die bestehende
betriebliche Entwicklungsfreigabe. Keine ungesicherte TLS-Zwischenstufe. Jede neue
Verbindung einschließlich Wiederaufnahme prüft Host/Netze erneut. Quell-App und deren
DB-Logger sind critical, Treiberfehler werden auf festen sicheren Text reduziert.

## Jobs und Wiederaufnahme

`migration_jobs` speichert queued/running/paused/failed/review/closed. Ein einzelner
Worker hält auf einer gepinnten DB-Sitzung GET_LOCK(`form_migration_jobs`). Nach Crash
werden laufende Jobs pausiert und verlangen menschliche Fortsetzung. P9 behält seinen
eigenen Importlock und Objekttransaktionen. Pause ist kooperativ nach bestätigtem Objekt;
fertige Objekte werden nicht zurückgerollt. Beim Dry-run wird weiterhin alles zurückgerollt.
Das Schema-HMAC muss vor Fachobjekten zum bewusst bestätigten Wert passen; ein
HMAC ist installationsschlüsselabhängig, kein universeller Literalwert im ADR.

Zähler werden nach Objektcommit gespeichert, Phasen sind echte P9-Tabellenphasen;
keine erfundenen Prozente/Restzeiten. Nach Durchlauf bleibt der Job `review`: das ist
keine Umschaltfreigabe. Der Worker ruft danach den idempotenten Konverter über dieselbe transaktionale
Operation wie die HTTP-Route auf. Sein autorisiertes Recht ist dabei migration.run;
die direkte Konverterroute behält system.manage. Im Jobergebnis werden nur IDs und
wertfreie Berichte aufgenommen, keine Entwurfsdokumente oder Mail-/Domainvorschläge.
Bei Fehler bleibt die bestätigte Importbilanz erhalten; Wiederaufnahme prüft das
Ledger und erzeugt keine doppelten Entwürfe. Die PWA kann den bestehenden
Konverter außerdem ausdrücklich erneut aufrufen.
Der normale Zielpool erhält vier statt zwei Verbindungen pro Eventloop, weil Workerlock,
Importertransaktion und Live-Abbruch-/Fortschrittskontrolle getrennte Sitzungen brauchen.

Neue Baseline-DDL und Vertrags-DDL sind gemeinsam fortgeschrieben. Für Bestände liegt
0026 nur als ungeprüfter Upgrade-Kandidat vor. Keine Schema-Prüfsummen umschreiben,
keine Bestandsmigration automatisch starten. Rechtezuweisung erfolgt ausdrücklich.

## Grenzen

Schema-Pin schützt Struktur, P9-Ledger schützt bereits importierte Inhalte. Es wird
weiterhin ein eingefrorener, freigegebener Snapshot benötigt; kein Live-Delta/Rollback.
Rechte-/Entschlüsselungsstichproben, SDK-Rollout, DNS-Wechsel und Umschaltfreigabe bleiben
außerhalb des Importers. MariaDB-, echte TLS-/PRF- und Browserabnahme stehen aus.

## Ergänzung P11-F Rest

ADR 0033 ergänzt explizite Delta-Prüfläufe mit neuem Snapshot-Hash und lokale
Browserstichproben. Vorhandene Pause/Quellentfernung/Settings-Deaktivierung bleiben
maßgeblich. Kein automatischer Datenrollback oder Cutover.
