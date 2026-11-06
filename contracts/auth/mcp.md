# MCP-, Token- und OAuth-Vertrag

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
**BESCHLOSSEN:** REST/MCP dürfen Entwürfe und Tests ermöglichen;
Veröffentlichung nur durch Menschen mit Bestätigung (ADR 0003 Nr. 13).
Alle Werkzeug-/Scope-/Token-/OAuthdetails hier sind **VORGESCHLAGEN**. Bestehende
Namen und Schwellen sind als Bestand kenntlich gemacht, keine Bestätigung neuer
Limits oder einer aktuellen externen Protokollversion.

## Transport, Identität und Scopes

Kanonisch POST `/mcp/`, `/mcp` ohne Redirect mit derselben Semantik. JSON-RPC 2.0,
`initialize`, `ping`, `tools/list`, `tools/call`; unterstützte MCP-Versionen im
Durchstich festlegen. Bestandsversionen aus A: 2025-06-18, 2025-03-26, 2024-11-05.
Keine ungeprüfte Behauptung vollständiger Streamable-HTTP-Kompatibilität; GET/SSE,
Resume und Transportversion sind **OFFEN**. VORGESCHLAGEN: zunächst POST-Antworten,
Notifications 202 ohne Body, unbekannte Methode -32601, unbekannte/zusätzliche
Argumente -32602. Fehlende/ungültige Beareridentität: HTTP 401 mit
`WWW-Authenticate` und Resource-Metadaten-Link. Rate-Limit HTTP 429 + Retry-After.
Autorisierte fachliche Ablehnung als Toolresultat `isError=true` ohne fremde IDs;
keine internen SQL-/Secretfehler. Requestlimit 64 KiB/Tiefe 16 VORGESCHLAGEN
(Bestand 16 KiB); größere Importe über begrenzten REST-Entwurfsupload.

Persönliche Tokens und OAuth-Access-Tokens nutzen denselben Kontext und die
Rechte aus `rechte.md`. `tools/list` filtert nach aktuellen Rechten; `tools/call`
prüft erneut. Toolannotations sind Bedienhinweise und keine Autorisierung.
`mcpErlaubt=false`, Kontosperre oder Widerruf sperrt jeden weiteren Aufruf.
Tokenzugriff auf Verwaltungs-REST ist ebenfalls auf folgende Aktionsmenge begrenzt:

| Scope | erlaubte Rechte (zusätzlich aktuelle Einzel-/Gruppenrechte und Bereich) |
| --- | --- |
| `statistik.lesen` (Bestand) | `statistics.read`, `form.read` ausschließlich für Formular-/Domainreferenzen |
| `konfiguration.lesen` | `form.read` ohne Secrets und produktive Zugangsdaten |
| `entwurf.schreiben` | `draft.write`, `draft.export`; kein Aktivieren/Veröffentlichen |
| `test.ausfuehren` | `test.run`, nur Simulation bzw. verwaltete Testziele |
| `debug.maskiert` | `debug.read`, `debug.export`, nur maskiert und TTL-begrenzt |

Scopes werden nicht automatisch ineinander eingeschlossen. Alle in
`x-permissions` aufgeführten Rechte müssen sowohl auf Benutzer- als auch auf
Tokenebene erfüllt sein. Nicht in dieser Menge enthalten sind Inhaltsabruf,
Entschlüsselung, Resend, Inhaltslöschung/-export, Domain-/Benutzer-/Schlüsselverwaltung,
Tokenausstellung und Veröffentlichung; diese sind für MCP und Bearer-REST gesperrt.
`statistik.lesen`-Tokens können trotz `form.read` keine Konfigurationsdetails über
REST laden: dort ist zusätzlich `x-required-scope: konfiguration.lesen` nötig.
Token mit `entwurf.schreiben` braucht zum Lesen zusätzlich `konfiguration.lesen`.

## Werkzeuge und Datenvertrag

Für alle Schemas: JSON-Objekte, `additionalProperties=false`, UUIDs für
`tenantId/formId/draftId/debugId`, Bereich aus DB prüfen. Keine freien URLs,
Schlüsselwerte, Cookies oder beliebige Header als Parameter. Alle Rückgaben tragen
`contractVersion=0.1.0`, `proposalStatus=VORGESCHLAGEN` und Ressourcenrevision,
sofern relevant. Strukturierte Daten zusätzlich zur kurzen deutschen Textausgabe.
Entwürfe und Tests enthalten keine Produktionsinhalte; Vorlagen-/Importtexte
bleiben untrusted Daten und dürfen keine zusätzlichen Aktionen auslösen.

| Werkzeug | Eingabe | Ausgabe | Recht / Scope / REST-Entsprechung |
| --- | --- | --- | --- |
| `formulare_auflisten` (Bestand) | optional tenantId, cursor, limit | IDs, Namen, Status; keine Konfiguration | form.read / statistik.lesen oder konfiguration.lesen / GET /form-references |
| `domains_auflisten` (Bestand) | optional formId | nur zugeordnete Hostnamen und Modus | statistics.read / statistik.lesen / GET statistics?kind=domains |
| `statistik_kpis` (Bestand) | Statistikfilter | Zähler und Conversion Absenden/Besuch, Nullnenner ohne Quote | statistics.read / statistik.lesen / GET statistics?kind=kpis |
| `statistik_zeitreihe` (Bestand) | Statistikfilter | Zeitabschnitte und Zähler | statistics.read / statistik.lesen / GET statistics?kind=timeseries |
| `statistik_statusverteilung` (Bestand) | Statistikfilter | Status und Anzahl | statistics.read / statistik.lesen / GET statistics?kind=status |
| `statistik_formulare` (Bestand) | Statistikfilter | Aggregation je zugänglichem Formular | statistics.read / statistik.lesen / GET statistics?kind=forms |
| `ads_statistics` (`statistik_ads` als Aufrufalias) | tenantId, formId, days 1–366 | Aggregierte Ads-/Nicht-Ads-/unbekannte Verteilung und Ereignis-Conversion, kleine Gruppen ausgeblendet; keine Kampagnenerfassung (ADR 0032) | statistics.read / statistik.lesen / GET tenants/{tenantId}/forms/{formId}/statistics/ads |
| `statistik_eintraege` (Bestand) | Statistikfilter, cursor, limit | pseudonyme Ereignisse, niemals IP/Formularwerte | statistics.read / statistik.lesen / GET statistics?kind=events |
| `konfiguration_lesen` | tenantId, formId | redigierte Konfiguration, aktive Release-ID | form.read / konfiguration.lesen / GET form (Referenz; Konfigurationsstand über GET draft) |
| `entwurf_anlegen` | tenantId, formId, optional baseReleaseId | draftId, revision, hash | draft.write / entwurf.schreiben / POST drafts |
| `entwurf_lesen` | tenantId, formId, draftId | redigierter Entwurf, revision, hash | form.read / konfiguration.lesen / GET draft |
| `entwurf_aendern` | tenantId, formId, draftId, expectedRevision, document | neue revision/hash, Validierungsbefunde | draft.write / entwurf.schreiben / PATCH draft (If-Match) |
| `entwurf_importieren` | tenantId, formId, kind=package oder php, source, optional expectedRevision | neuer Entwurf plus Konvertierungswarnungen, nie ausführendes PHP | draft.write / entwurf.schreiben / POST imports |
| `entwurf_exportieren` | tenantId, formId, draftId | Konfigurationspaket ohne Secrets/Inhalte | draft.export / entwurf.schreiben / GET draft/package |
| `entwurf_testen` | tenantId, formId, draftId, expectedRevision, input, optional testTargetId | testId, redigierte Schrittresultate und Fehler | test.run / test.ausfuehren / POST tests |
| `debug_starten` | tenantId, formId, releaseId, mode=observe oder test, optional correlationId | debugId, expiresAt, status | debug.read / debug.maskiert; mode=test zusätzlich test.run und test.ausfuehren / POST debug-jobs |
| `debug_lesen` | tenantId, formId, debugId | maskierte Ereignisse | debug.read / debug.maskiert / GET debug-job |
| `debug_exportieren` | tenantId, formId, debugId | ausschließlich maskierte Traceausgabe | debug.read UND debug.export / debug.maskiert / GET debug-job/export |

Statistikfilter VORGESCHLAGEN: optional formId/domain, period aus Bestand
24h/today/7d/30d/year/custom; custom mit from/to, maximal 366 Tage; cursor und
limit 1–100, Standard 50. Vor Paginierung Bereich prüfen. Bestandsparameter
`seite` über Adapter erhalten; Zeitzonen-/Fenstersemantik mit Datenvertrag abgleichen.

Tests simulieren Produktionseffekte. Reale Testaufrufe nur mit `test.run`,
explizit verwaltetem Testziel, SSRF-Schutz, Empfänger-Allowlist und Kennzeichnung
als Test; keine unkontrollierten Skripte oder Produktionstoken. Importiertes PHP
wird als Text konvertiert, nicht ausgeführt; es erzeugt ausschließlich Entwürfe.
Debugbeobachtung verändert den laufenden Vorgang nicht, TTL 15 Minuten und
Maskierung bleiben auch für Token mit Adminbesitzer verbindlich.

## Veröffentlichung durch Menschen

VORGESCHLAGEN, um ADR 0003 Nr. 13 durchzusetzen:

1. Mensch lädt Kandidat mit fixierter Revision und Hash, prüft Diff, Testbefunde,
   Ziele, aktive Modul-/Sandboxreferenzen. Freeze des Kandidaten vor Bestätigung.
2. `POST .../publication-confirmations` verlangt interaktive DB-Sitzung,
   release.publish, CSRF, frische Authentifizierung und ausdrückliche Bestätigung
   genau dieses Hashs. Die UI zeigt Folgen für Produktion, Empfänger und Domains.
3. Server erzeugt opake einmalige confirmationId, gebunden an Konto, Sitzung,
   Kunde/Formular, Kandidatenhash/-revision und Aktion, Frist **VORGESCHLAGEN 120s**.
   Bestätigung wird als reines Geheimnis behandelt, nie in Logs/URLs/MCP-Ausgaben.
4. `POST .../releases` derselben menschlichen Sitzung verbraucht Bestätigung und
   prüft Rechte, Version und Hash atomar. Release und Auditereignis werden gemeinsam
   geschrieben; daraus erzeugt Server `publication.actorKind=human`, confirmedAt
   und confirmationAuditId für den Flow-Vertrag. Geänderter Kandidat erfordert
   neue Bestätigung. Wiederholung mit gleichem Idempotenzschlüssel liefert dasselbe
   Ergebnis; verbrauchte Bestätigung darf keine zweite Veröffentlichung erzeugen.

Beide Operationen akzeptieren ausschließlich Sitzung, keine manuellen/OAuth-
Tokens, Serviceidentitäten oder Clientbehauptungen `human/confirmed=true`.
Keine MCP-Werkzeuge zum Bestätigen, Publizieren, Aktivieren, Rollback oder Setzen
der Produktionsdomain. Auch indirekte Publikation über Draftpatch, Import,
Webhooktoggle, Modusfeld, Domainmapping oder asynchrone Jobs ist verboten.
Rollback erzeugt einen neuen bestätigten Release. Ein menschlicher Besitzer eines
Tokens macht den Tokenaufruf nicht zu einer menschlichen Veröffentlichung.
Das System prüft den vorgesehenen interaktiven Freigabeprozess; eine allgemeine
technische Garantie gegen Browserautomatisierung wird damit nicht behauptet.

## Persönliche Tokens

VORGESCHLAGEN: kryptografisch zufälliger 256-Bit-Wert, einmalig bei Anlage
anzeigen, nur Hash plus nicht geheime ID/Präfix in DB. Bestandsform `kfm_` plus
64 Hexzeichen kann als Adapterformat erhalten bleiben; bestehende Token werden
nicht still mit Schreibrechten ausgestattet. Anfangsscope ausschließlich
statistik.lesen. Mehr Rechte nur nach neuer menschlicher ausdrücklicher Freigabe.
DB: subjectId, Label, scopes, begrenzte tenantIds/formIds, erstellt, expiresAt,
lastUsedAt, revokedAt, ggf. grantId. Rechte/Bereich nur verkleinern, Erweiterung
über Neuausstellung. Keine Rechte im zufälligen Token selbst vertrauen.

Schwellen **VORGESCHLAGEN**, aus Bestand B: Label 1–120 Zeichen, Gültigkeit
1–90 Tage, maximal fünf aktive persönliche Tokens/Konto. Tokenanlage und
Widerruf über Konto, Sitzung+CSRF+frische Authentifizierung; keine Tokenverwaltung
mit Token. Einzelwiderruf, Konto-/MCP-Sperre und Grantwiderruf wirken sofort
replikaübergreifend. Audit enthält Kennungen und Ergebnis, nie Token, Header,
Passphrase, TOTP-Secret oder Formularwerte.

## OAuth

VORGESCHLAGEN: öffentliche Clients mit Authorization Code + PKCE S256, keine
Implicit-/Password-/Client-Credentials-Grants. Endpunkte auf fester Admin-Origin:

| Pfad / Methode | Vertrag und Altparität |
| --- | --- |
| `/.well-known/oauth-protected-resource` GET/HEAD | resource exakt konfigurierter /mcp/-URL; authorization_servers; entspricht /mcp/oauth/ressource/ |
| `/.well-known/oauth-authorization-server` GET/HEAD | fester issuer, authorize/token/register, erlaubte scopes und S256; entspricht /mcp/oauth/server/ |
| `/mcp/oauth/register/` POST | begrenztes JSON, Redirect-Allowlist, public client auth none, kein offener Redirectregistrierungsdienst |
| `/mcp/oauth/authorize/` GET/POST | Parameter prüfen, angemeldeter Mensch, ausdrückliche Consentansicht mit Scope und Kunde/Formular; POST CSRF+frische Bestätigung |
| `/mcp/oauth/token/` POST | form-urlencoded, code/refresh Grant, client_id, code_verifier, exakte redirect_uri und resource, keine Cookieauth |
| `/mcp/oauth/revoke/` POST | VORGESCHLAGENE Ergänzung: Token/Grant für passenden Client atomar widerrufen, keine Tokenexistenz verraten; zusätzlich Konto-UI-Widerruf |

Redirect-URI exakt registriert UND durch Betriebs-Allowlist erlaubt, HTTPS;
Loopback-Ausnahmen nur gesondert bestätigtes Profil (**OFFEN**). Kein Fragment,
keine Wildcards. response_type=code, state an Clienttransaktion gebunden und
unverändert zurück; issuer im Rücklauf prüfen. Code an Client, Redirect, Resource,
Scope, Konto/Grant und PKCE binden; einmaliger atomarer Verbrauch. Fehlender
resource-Wert wird im neuen Entwurf abgelehnt (**VORGESCHLAGENE Verschärfung**
gegenüber optionalem Altparameter). Resource und Audience sind exakt /mcp/,
kein Tokenaustausch für fremde APIs. REST-Beareradapter bleibt derselbe
Resource-Server und verlangt denselben Audiencewert plus Endpunktscope.

Refreshrotation atomar, jeder Refresh einmalig; Wiederverwendung widerruft
Familie/Grant und alle davon abhängigen Access-Tokens. Parallele Verwendung
darf nicht zwei gültige Nachfolger erzeugen. Refresh darf Rechte, Scope und
Bereich nicht erweitern. Grantzustand bei jedem Zugriff prüfen; Ablauf/Widerruf
wirkt auch vor Access-Tokenfrist. Tokens opak, nur Hash speichern; keine
Refresh-/Accesswerte in URLs, Logs oder Consent-Audits.

Aus Bestand übernommene, für Neubau **VORGESCHLAGENE** Werte: Code 60s, Access 1h,
Grant-/Refreshhorizont maximal 30 Tage ab Consent ohne gleitende Verlängerung;
maximal zehn Grants/Konto, fünf Redirects/Client, 200 Clients gesamt, 40 ausstehende,
Registrierung 1h ausstehend. Register-/Tokenbody maximal 8192 Byte,
PKCE-Verifier 43–128 Zeichen aus A–Z/a–z/0–9/-._~, Redirect/state maximal 512 Byte.
Unbekannter Scope/unerlaubter Resource/Redirect wird abgelehnt; bei ungültigem
Redirect keine Fehlerweiterleitung. Neue Schreibscopes sind opt-in, nicht aus
altem statistik.lesen-Grant ableitbar. Ein release.publish-Scope existiert nicht.
Vor Implementierung ist ein gesonderter Abgleich mit den dann geltenden
MCP-/OAuth-Spezifikationen und den Zielclients erforderlich.

Technischer Nachtrag 27.10.2026 — **VORGESCHLAGEN**: Publikationsbestätigungen
liegen dauerhaft in `publication_confirmations`; Bindung, Einmalverbrauch,
Sitzungsrotation und Replay nach Antwortverlust gemäß `anmeldung.md` und
`../data/abbildung.md`. Paketexport liefert direkt `../flow/package.schema.json`
mit allen transitiven erlaubten Definitionen, Modulen/Bausteinen, Skripten,
Sandboxanforderungen, Vorlagen und Verbindungsaliasen. Export und anschließender
Import verwenden dieselbe Paketstruktur, Import bleibt draft-only und ohne
Außenwirkung; Secrets oder Produktionsaktivierung sind kein Paketbestandteil.

Import-Wirehülle bleibt `ImportInput`: `kind=package`, `source` enthält den
UTF-8-JSON-Text genau dieser Exportantwort. Nach Parsing gegen dasselbe
Paketschema und alle transitiven Referenzen prüfen; kein Draft-DTO als Ersatz.


## ADR 0004 M05/H02 — Migration und aktuelle Rechte

**BESCHLOSSEN ADR 0005 D4 (ersetzt ADR 0004 Nr. 8):** Bestehende OAuth-/MCP-
Credentials (`oauth_clients/grants/codes/refresh_tokens`, `mcp_tokens` des Altsystems)
werden **nicht** übernommen. Alle MCP-/OAuth-Clients melden sich nach dem Cutover neu
an; Altgrants, -codes, -refreshwerte und Alttokens verfallen mit dem Cutover und werden
nicht importiert (Cutover-Folge siehe unten). Details der Datenseite:
[Mapping](../data/migration-mapping.md). Ob handerzeugte Alt-`mcp_tokens` darunter
fallen, ist aus dem ADR-Wortlaut („OAuth/MCP-Altcredentials") abgeleitet; Rückfrage
ist im Handoff vermerkt.

Gruppen-/Einzelentzug wirkt auch für übernommene Tokens über aktuelle
rights_version. `flow.execute/approve/resume` im Benutzerkatalog erweitern
keine MCP-Scopes; menschliche approve/resume-Freigabe bleibt Tokens verwehrt.

## ADR 0005 D4 — Neuanmeldung statt Legacyprofil (BESCHLOSSEN)

Stand 29.10.2026. Der in Vertragsrunde 3 vorgeschlagene Legacyprofil-Entwurf
(`resource_binding='legacy-unbound'`, Akzeptanz fehlender `resource`, Import von
Refreshfamilien) ist **entfernt**. Es gibt kein Legacyprofil am Tokenendpunkt.

- **Resource-Pflicht (neue Credentials, bleibt):** Jede Autorisierung verlangt
  `resource`; gespeichert wird `oauth_*.resource` (NOT NULL, exakt die konfigurierte
  `/mcp/`-Resource). Fehlt der Parameter oder weicht er ab: `invalid_target`.
  Access-Tokens tragen Audience = diese Resource.
- **Refresh-Replay und Parallelität (neue Credentials):** ersetzter oder bereits
  verbrauchter Refreshwert → Familie widerrufen (`family_id` NOT NULL): Grant
  `revoked_at`, Refreshwerte, offene Codes (`revoked_at`) und alle `mcp_tokens` mit
  diesem `grant_id` in **einer Transaktion**. Parallele Einlösung: bedingtes Update
  `WHERE replaced_at IS NULL AND revoked_at IS NULL`; genau ein Nachfolger, der
  Verlierer gilt als Replay.
- **Cutover-Folge:** (1) Nach dem Umstieg sind keine Altcredentials gültig; jeder
  Client (Desktop-/Agentenclients, Integrationen) durchläuft neue Dynamic Client
  Registration bzw. Autorisierung mit PKCE und `resource`. (2) Altgrants verfallen,
  nichts wird verlängert oder aufgefüllt. (3) Betroffene Betreiber/Nutzer vor dem
  Cutover informieren; Kommunikationstext ist Betriebsaufgabe. (4) Abnahme: Alt-
  Tokenwerte werden am neuen System abgelehnt (`invalid_token`/`invalid_grant`),
  Neuanmeldung funktioniert, `resource` Pflicht, Replay/Parallelrefresh, Grantwiderruf
  wirkt auf Codes/Tokens. Nicht ausgeführt.

## Laufzeitprofil v1 – Paket MCP/Tokens (03.11.2026)

Das beauftragte erste Laufzeitprofil implementiert persönliche Tokens zuerst; OAuth
oben bleibt Rest, weil es hier nicht verbindlich für v1 gefordert ist. Exakte
Scope-/Bereichs-/Transportauswahl, HTTP-DTOs und bewusst kleinere Werkzeugmenge:
[ADR 0018](../../docs/decisions/0018-mcp-tokens.md). Tatsächliche Abnahmegrenzen
(DB-/Browserlauf blockiert) und nächste Schritte:
[Übergabe P8 MCP](../../docs/handoffs/P8-MCP.md). Dies bestätigt weder offene
OAuthdetails noch eine Übernahme alter Credentials.
