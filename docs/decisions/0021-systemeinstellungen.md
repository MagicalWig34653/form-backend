# ADR 0021: Systemeinstellungen über ENV und PWA

Status: beschlossen durch Nutzerauftrag P11-B, 03.11.2026.

## Entscheidung

FormCore hält die zentrale Registry (Schlüssel, Typ, Grenzen, Standard, ENV-Name,
Neustartpflicht und Sensibilität). Persistenz liegt in `settings`, `scope_key='system'`.
Die Rangfolge lautet ENV > DB > Default. Bereits das Vorhandensein einer ENV-Variable
sperrt Änderungen; auch eine leere ENV-Angabe zählt. Ungültige Werte werden abgelehnt.
Bootstrap bleibt ausschließlich ENV: DB-Zugang/TLS, Serverschlüssel, Listener/Ports,
vertrauenswürdige Proxys, allowInsecure, Dashboard-Schalter sowie Schema-/PWA-Pfade.

Registryumfang nach tatsächlichem Sources-Bestand: Mail-Netze, Log-Level,
SDK-Verzeichnis, drei Webhookquoten, Admin-Origin/RP-ID und neu
`FORM_MCP_TOKEN_RATE_LIMIT` (Standard 60 Anfragen/Minute je Token, 1–100000).
Webhooks erlauben 0 zum Sperren neuer Aktivierungen bzw. zum sofortigen terminalen
Abschluss neuer Outboxeinträge. Obergrenzen: Formular 10000, Kunde 100000,
Rückstau 10000000. In diesem Branch gibt es keine ENV für allgemeine Speicherlimits
oder Aufbewahrungsstandard; diese Gruppen erklären das in der UI und erfinden keine
neuen Einstellungen. Codebezeichner englisch/Nutzertexte deutsch gemäß ADR 0001.

`GET/PUT /admin/api/v1/settings` setzt menschliche Sitzung, frischen Login und
explizites Systemrecht `system.settings` voraus. PUT verlangt CSRF/Origin. Keine
Tokenfreigabe und keine implizite Vererbung aus `system.manage`. Werte sind kanonischer
Text, auch bei Typ integer (keine Coercion, Leerzeichen oder Exponentialschreibweise).
GET liefert `{revision,items:[{definition,value,source,locked}]}`. PUT akzeptiert nur
`{revision,values:{key:text}}`; unbekannte Schlüssel, Duplikate, falsche Typen, ENV-
Überschreibungen und ungültige Werte scheitern. HTTP 409 signalisiert Revisionskonflikt.

Die interne Zeile `_revision` wird unter Transaktionssperre angelegt/gelesen und mit
jedem PUT durch eine UUID ersetzt. GET nutzt dieselbe Sperre für konsistente Snapshots.
Mutation, Revision und Audit sind atomar. Audit enthält ausschließlich Schlüsselnamen,
niemals Werte (auch bei künftig sensiblen Einträgen). Sensible Werte werden nicht
zurückgegeben. Zurzeit enthält die Registry keine Geheimnisse.

MCP-Limit und Webhookquoten werden je Operation aus der Registry gelesen. REST-
Tokenbudget bleibt 120/min und erhält einen getrennten Zähler. Explizite
Webhook-Testkonfigurationen bleiben möglich. Alle übrigen Werte sind als
restartRequired markiert und werden beim Start aus DB+ENV zusammengeführt.
Admin-Origin und RP-ID werden gemeinsam auf Konsistenz geprüft. Der Serverschlüssel
bleibt Voraussetzung zum Aktivieren der Admin-API; Origin/RP-ID können dann aus DB
kommen. Startfehler schließen die API, statt ungültige Konfiguration zu übernehmen.

## Folgen und Migration

Keine neue Tabelle. Baseline und Vertrags-DDL enthalten das neue Recht. Bestehende
Installationen benötigen ein separat geprüftes, versioniertes Upgrade des Rechtekatalogs
und explizite Zuweisung an berechtigte Konten. Der aktuelle Baseline-Runner ist dafür
nicht geeignet: geänderte Baselinechecksummen nicht überschreiben. P11-B führt keine
Bestandsmigration aus und gewährt vorhandenen Konten kein neues Recht automatisch.
DB-Nebenläufigkeit, Auditrollback und Bestandsupgrade benötigen MariaDB-Abnahme.

Ein idempotenter SQL-Upgradeentwurf für den Katalog liegt unter
`backend/db/upgrades/0021-system-settings.sql`; er ist nicht automatisch an den
Baseline-Runner angeschlossen und erteilt bewusst keine Rechte. Vor Bestandsbetrieb
sind Upgrade und explizite Systemzuweisung freizugeben und zu testen.
