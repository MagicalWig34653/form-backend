# ADR 0026: Begrenzte MCP-Statistikauswertung

Stand: 03.11.2026, Paket MCP-Werkzeuge. Beschlossen durch Nutzerauftrag; expliziter Statistikscope
am 03.11.2026 bestätigt.

## Entscheidung

Die sechs Werkzeuge heißen `statistik_kpis`, `statistik_zeitreihe`,
`statistik_statusverteilung`, `statistik_formulare`, `statistik_eintraege` und
`statistik_ads`. Sie verwenden den bestehenden Streamable-HTTP-/JSON-RPC-Eingang.
Jeder Aufruf adressiert explizit `tenantId` und `formId`; keine implizite Ausweitung
auf sämtliche Kunden. `days` ist 1–366 (Standard 30), `limit` 1–100 (Standard 50).
Zeitfenster: UTC-Kalendertage einschließlich heute, ausschließlich Produktion.
Unbekannte Argumente, fehlende/ungültige UUIDs und übergroße Grenzen scheitern mit
JSON-RPC -32602. Zeitreihen haben höchstens 366 Zeilen; Ereignisse liefern
`truncated` und keine frei verschiebbaren Offsets. Keine Vorschlagskennzeichnung
für gemessene Statistikwerte.

Es gilt der explizite Scope `statistik.lesen` → `statistics.read`, damit
bestehende Konfigurationsfreigaben nicht still erweitert werden. Tokenbindung und
`PermissionService` müssen bei jedem Aufruf erfüllt sein. Die Werkzeugliste
berücksichtigt auch kundengebundene Tokens mit einzelnen Formularrechten. Keine
Sonderrechte anhand von Rollen oder UI-Zuständen. Rechteentzug gilt sofort.

Der Ereignisbestand und der begrenzte Vor-Einführung-Fallback entsprechen
`StatisticsRoutes` (Einführung 03.11.2026 UTC, akzeptierte Einsendungen,
13 Monate, Löschsperre, keine doppelten submit-Ereignisse). Aggregatmodell und
Berechnung verwenden `StatisticsRoutes.Body/Day`. Der SQL-Lesepfad liegt wegen
des vorgegebenen Dateibesitzes separat; ein späterer gemeinsamer Reader für REST
und MCP muss diesen Vertrag und die Paritätsprüfung erhalten.

Status zeigt ausschließlich `accepted` aus submit-Ereignissen/Fallback;
`errorStatusesAvailable=false` macht die fehlende Fehlerstatistik sichtbar.
Es werden keine technischen HTTP-Fehler aus Audit oder Debug zu Statistik erfunden.
Ads liefert `available=false` mit deutscher Begründung: Der Neubau speichert
keine Ads-Merkmale. Die benötigte GCLID-Erfassung folgt ausschließlich im eigenen Paket **P13-Ads**
(Nutzerbestätigung 03.11.2026). Keine Besucherverknüpfung aus Pseudonymen nachbauen.
Formularauswertung ist absichtlich auf das adressierte Formular beschränkt.

Ereignisprojektion enthält ausschließlich Zeitpunkt und Ereignisart; keine IDs
von Einsendungen/Besuchern, Pseudonyme, Schrittwerte, Domains, Inhalte oder Metadaten.
Neue Werkzeugaudits enthalten Aktion, Zeitpunkt und Kunden-/Formularbezug,
keine Konto-/Tokenidentität, Argumente oder Ergebnisse. Bestehendes Token-use-Audit
bleibt unverändert. Fehler bleiben generisch; keine internen SQL-Fehler nach außen.

## Bestehende Verträge und Folgen

`ConfigurationIdentity.require` zählt die Anfrage bereits einmal je Token und
Minute über `SystemSettings.value("mcp.requestsPerMinute")`; ENV > DB > Default
und getrenntes REST-Budget gemäß ADR 0021 bleiben erhalten. Kein zweiter Zähler.

FA-124 ist im Checkout bereits durch `OAuthRoutes.registerPublic/metadata`
umgesetzt: `/.well-known/oauth-authorization-server` neben Ressourcenmetadaten,
Issuer, interne Autorisierung, öffentliche Token-/Registrierungsendpunkte, code,
PKCE S256, öffentliche Clients und unterstützte Scopes. Prüfung gegen
[RFC 8414, Abschnitte 2 und 3](https://www.rfc-editor.org/rfc/rfc8414).
Kein zweiter Discovery-Endpunkt und keine Änderung an OAuth-Dateien.

Keine neuen Tabellen, Spalten oder Katalogrechte: kein Schema-/Upgrade-SQL und
keine Anpassung des Splitter-Zählers nötig. Deutsche UI-Textschlüssel werden nur
unter `mcpStatistics` angehängt; keine Oberfläche außerhalb des Dateibesitzes ändern.
DB-Abnahme und unabhängiges Sicherheitsreview stehen vor Bestandsbetrieb aus.

## Fortschreibung P13-Ads (03.11.2026)

Der Ads-Platzhalter ist durch ADR 0032 abgelöst. `ads_statistics` liefert die echte
Aggregatprojektion des gemeinsamen REST-/MCP-Readers; `statistik_ads` bleibt als
Aufrufalias erhalten. Scope und Rechte bleiben unverändert. Keine Kampagnenwerte
im geprüften Altcode, daher `campaignsAvailable=false`. Schemaänderung, Privacy-
Schwelle und Ereignisquote sind in ADR 0032 festgelegt.
