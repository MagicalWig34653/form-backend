# ADR 0022 – OAuth für MCP mit zwei Listenern

03.11.2026. Status: Umsetzung gemäß Nutzerauftrag P11-E; unabhängiges Sicherheitsreview und Laufzeitabnahme offen.
Todolino D260A5A3-0EDC-455E-9289-C705055160D3. 0021 ist auf `feature-settings` belegt.
SPDX-License-Identifier: AGPL-3.0-only.

## Entscheidung und Begründung

P11-E ergänzt ADR 0018/0020 um ein OAuth-2.1-Profil für öffentliche Clients: ausschließlich
Authorization Code mit obligatorischem S256 und Refresh-Rotation, Clientauthentifizierung `none`.
Kein implicit/password, kein Clientsecret, kein automatisches Vertrauen durch Registrierung.
Claude/ChatGPT sind Zielclients; tatsächliche Kompatibilität muss separat abgenommen werden.
Grundlagen: [MCP-Autorisierung 2025-06-18](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization),
[RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html),
[RFC 9728](https://www.rfc-editor.org/rfc/rfc9728.html),
[RFC 8414](https://www.rfc-editor.org/rfc/rfc8414.html),
[RFC 7591](https://www.rfc-editor.org/rfc/rfc7591.html),
[RFC 7009](https://www.rfc-editor.org/rfc/rfc7009.html),
[RFC 9207](https://www.rfc-editor.org/rfc/rfc9207.html).

Öffentlich: beide Well-known-Metadaten, POST `/oauth/register`, POST `/oauth/token`, MCP.
Intern: GET/POST `/oauth/authorize`, POST `/oauth/revoke`, eigene Grant-/Clientverwaltung unter
`/admin/api/v1/account/oauth`. Autorisierung und Verwaltung werden nur beim expliziten öffentlichen
Dashboard zusätzlich öffentlich. Widerruf nach RFC 7009 verwendet Client-ID und Token, keine Cookieauth;
PWA-Eigenwiderruf verwendet Sitzung, CSRF und frische Anmeldung, auch nach Rechteentzug.

`FORM_OAUTH_ISSUER` ist die kanonische öffentliche HTTPS-Origin, Resource exakt `<issuer>/mcp/`.
Ohne Einstellung gilt die Admin-Origin (für Installationen mit gemeinsamem Proxy-Origin).
Bei getrennten Domains muss der Betreiber die öffentliche Origin setzen. `FORM_OAUTH_AUTHORIZE_BASE_URL`
bezeichnet eine HTTPS-Origin für `/oauth/authorize`; Default Admin-Origin. Abweichende Origin muss zu
einem eingeschalteten öffentlichen Dashboard gehören. Metadaten und `iss` verwenden ausschließlich
Konfiguration, nie Host-/Forwarded-Header. Beide Einstellungen sind in der aus `feature-settings`
übernommenen Registry; ENV > DB > Default, OAuth-Originänderungen erfordern Neustart. RP-ID/Passkey-Origin
bleiben gemäß ADR 0020 beschränkt. Interne Autorisierungsseite muss im Browser erreichbar sein.

Dynamische Registrierung: 5/min pro tatsächlicher/vertraut aufgelöster Client-IP; maximal zehn Redirects,
HTTPS oder HTTP exakt localhost/127.0.0.1/::1. Keine Userinfo, Fragmente, Backslashes oder bereits belegten
OAuth-Antwortparameter. Exakter Stringabgleich ohne Wildcards/Hostsuffix/Port-Ausnahme. Unbekannte
Registrierungsmetadaten werden ignoriert und niemals abgerufen. Ein Client hat ohne menschlichen Grant
keinen Zugriff. Consent zeigt Clientname, Redirect-Host, Scopes und eine ausdrücklich gewählte
Kunden-/Formulargrenze. Login/CSRF/Origin verwenden die bestehenden PWA-Dienste; frische Anmeldung
maximal fünf Minuten. Consent ist fünf Minuten an genau eine Sitzung gebunden und einmalig.
GET führt auf `/api-tokens?oauth_request=<UUID>`, POST liefert der PWA die geprüfte Redirect-URL als JSON.
Antwort enthält `iss` und unverändertes `state`, auch bei Ablehnung. Keine Umleitung bei ungültigen Parametern.

Code: zufällig 256 Bit, SHA-256 gespeichert, 60 Sekunden, einmalig, über Grant an Client, Resource,
Redirect und S256 gebunden. Access: zufällig 256 Bit, SHA-256 gespeichert, 15 Minuten.
Refresh: 30 Tage absolute Grantfrist, keine gleitende Verlängerung, Rotation bei jeder Verwendung.
Grantzeilensperre serialisiert Codeverbrauch, Refreshwechsel, Widerruf und Auflösung über Replikas.
Refresh-Replay widerruft die gesamte Familie einschließlich ihrer Access-Tokens über den Grant;
Widerruf wird vor der Fehlerantwort committed. Jeder Grant hat genau eine Refreshfamilie.
Parallele Refreshversuche können deshalb absichtlich zur Sperre führen; Clients müssen serialisieren.
Tokenausstellung und Auditereignis sind atomar. Geheimnisse erscheinen nur in den erforderlichen
Protokollantworten und nie in Auditdetails, Listen oder Logs. Proxy-Body-/Authorization-Logs sind zu deaktivieren.

Scopes bleiben `konfiguration.lesen` und `entwurf.schreiben`; keine Entschlüsselung/Publikation.
Consent/Ausstellung/Auflösung prüfen Kontoaktivität, MCP-Erlaubnis, Eigentumskette und alle Scoperechte
live durch PermissionService. Tool-/REST-Aktionen prüfen anschließend unverändert ihre Fachrechte.
Eine entzogene Scoperechtskomponente macht den ganzen OAuth-Token sofort unbrauchbar.
Die bestehende Tokenidentität wird weiterverwendet; keine zweite MCP-Fachlogik.
Pro Token gilt für persönliche und OAuth-Tokens die vorhandene Registryeinstellung
`mcp.requestsPerMinute` / `FORM_MCP_TOKEN_RATE_LIMIT` (Default 60/min, live, ENV gewinnt).
IP-Budget und interner Dispatch bleiben gemäß ADR 0018 getrennt.

## Schema und Grenzen

Bestehende OAuth-Tabellen werden aktiviert: `oauth_grants.scope_json` ergänzt den Bereich;
`oauth_authorization_requests` ist neu, S256-CHECK und Familienindex kommen hinzu.
Keine Altcredentials übernehmen. Nur Schema-Entwurf geändert, keine produktive Migration.
Der Baseline-Migrationsrunner ist kein Upgradepfad für existierende Installationen; eine versionierte
Bestandsmigration muss vor einem Einsatz separat bereitgestellt und geprüft werden.
Abnahme/Prüfungen und verbleibende Grenzen: `docs/handoffs/P11-E.md`.

## Defensive Audit-Nachkorrektur (03.11.2026)

Nutzerauftrag: DCR zusätzlich zum unveränderten IP-Budget global begrenzen. Registry:
`oauth.registrationsPerHour` / `FORM_OAUTH_REGISTRATIONS_PER_HOUR` (200, 1–100000)
und `oauth.maxUnusedClients` / `FORM_OAUTH_MAX_UNUSED_CLIENTS` (1000, 1–100000).
Beide live, ENV > DB > Default. Erfolgreiche Registrierungen der letzten gleitenden Stunde
werden anhand `created_at` gezählt; ungenutzt bedeutet ohne jeglichen Consent-Grant,
auch widerrufene/abgelaufene Grants bleiben als Nutzungsnachweis erhalten. Bei Erschöpfung
HTTP 429. Gemeinsame Settings-Zeilensperre vor Zählung/Insert, Consent und Bereinigung
serialisiert Replikas; Insert und bisheriges wertfreies Registrierungsaudit bleiben atomar.

Ohne Grant endet die Registrierung nach 24 Stunden (seit 14.11.2026: 1 Stunde, siehe Nachtrag unten). Autorisierung/Consent lehnen sie
ab dieser Grenze ab; AuthMaintenance entfernt sie samt ausstehenden Consentanfragen
in begrenzten Batches. Fehlendes historisches `created_at` gilt ohne Grant als abgelaufen.
Audit `oauth.client.expire` enthält ausschließlich die Batchanzahl, keine Namen, Redirects,
Konto-, Sitzungs- oder Clientkennungen. Die Frist ist unabhängig von der siebentägigen
Auth-Aufbewahrung. Keine Schemaänderung oder produktive Migration nötig.

PWA: Keyring an Konto-ID und den sitzungsstabilen CSRF-Token ausschließlich im Speicher
binden. Wechsel sperrt vor weiteren Kontodatenabrufen, nullt Schlüssel und invalidiert
laufende Kryptooperationen. Abmeldung/Identitätswechsel senden ein wertfreies
Invalidierungssignal per BroadcastChannel und Storage-Event; empfangende Tabs sperren
sofort ohne Echo und verwerfen verspätete Identitäts-/Kundenantworten. Weder Konto-ID
noch CSRF-Token/Schlüssel werden übertragen oder persistiert. Neue Tab-Initialisierung
sperrt bestehende Tabs vorsorglich ebenfalls. Browser-/DB-Laufzeitabnahme bleibt separat.

## Härtung der öffentlichen Registrierung (14.11.2026)

Das IP-Budget der Registrierung (5/min) überschritt den globalen Stundendeckel (200): eine Adresse konnte ihn allein
ausschöpfen. Jetzt 10 Registrierungen pro Stunde je Adresse, IPv6 auf das /64-Präfix normalisiert
(`IPAddr.quotaKey`). Ungenutzte Clients (ohne jeden Grant) verfallen nach 1 Stunde statt 24 Stunden
(`OAuthService.unusedClientTTL`, Bereinigung und Consent-Prüfung). Feste Konstanten, keine neuen Einstellungen.
