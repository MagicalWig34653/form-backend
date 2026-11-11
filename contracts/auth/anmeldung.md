# Anmeldung, Sitzungen und Missbrauchsschutz

Stand: 26.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Beschlossen (ADR 0002 Nr. 16): Passkey bevorzugt, Passwort-Lockout und Backoff je
Konto und IP, Rate-Limit für alle Admin-Routen. Admin-Domain/RP-ID bleiben erhalten
(ADR 0003 Nr. 12). Alle weiteren Verfahren, Zeitwerte und Schwellen unten sind
**VORGESCHLAGEN**, sofern nicht ausdrücklich als Bestand bezeichnet.

## Passwort und Faktorstatus

VORGESCHLAGEN: Passwortprüfung mit gepflegtem Passwort-Hashverfahren; Argon2id
als Ziel, Parameter erst nach Messung im Durchstich bestätigen. Bestands-Hashes
über kompatiblen Prüfer verifizieren und bei erfolgreichem Login neu hashen.
Keine Passwortnormalisierung oder heimliche Kürzung. Neue Passwörter mindestens
12 Unicodezeichen, Höchstlänge 1.024 UTF-8-Byte; Algorithmen-/Parametervertrag und
Bestandsgrenzen vor Implementierung prüfen. Generischer Anmeldefehler für
unbekannt/gesperrt/falsch, gleichwertiger Dummy-Hashpfad, keine Kontoexistenzliste.

Zustände: `anonymous -> factor_pending -> authenticated -> revoked/expired`.
Passwort korrekt plus eingerichtetes TOTP ergibt nur eine faktorbegrenzte
Zwischensitzung. Sie kann weder REST-Ressourcen lesen noch OAuth-Freigaben oder
MCP-Tokens ausstellen. Ohne eingerichtetes MFA ist Passwortlogin im Entwurf
weiter möglich; MFA-Pflicht für privilegierte Rollen ist **OFFEN**.

TOTP-Bestand laut B: sechs Ziffern, 30 Sekunden, SHA-1, ±1 Schritt; fünf Versuche,
900 Sekunden Sperre. VORGESCHLAGEN für Neubau: kompatible Parameter erhalten,
akzeptierten Schritt atomar je Konto speichern und Wiederverwendung auch auf
einer anderen Replika ablehnen. Enrollment: frische Authentifizierung, lokaler
QR-Code, Secret nur in Einrichtung und verschlüsselt in DB, Aktivierung erst nach
korrektem Code. Entfernen/Ersetzen braucht frische Bestätigung; kein Secret in
Audit/URL. Legacy-MFA-Formate ausschließlich im Migrationsvertrag auflösen.

## WebAuthn und Datenzugang

VORGESCHLAGEN: getrennte Registrierung und Anmeldung, serverseitige einmalige
Challenges gebunden an Sitzung, Zweck und ggf. Konto; Verbrauch atomar auch im
Fehlerfall nach einem Prüfversuch. Challengefrist 120 Sekunden. Prüfung von Typ,
Challenge, exakter konfigurierter Origin, RP-ID-Hash, Credential, UserHandle,
Signatur, User Presence und User Verification. Kein RP-/Origin-Wert aus Host,
Forwarded oder Kundendomain ableiten. Details in `domains-proxy.md`.

**VORGESCHLAGEN (ADR 0006 Nr. 12, P3-C):** Eigene Verifikation mit swift-crypto fuer
ES256 (-7), RS256 (-257), EdDSA (-8); Schluessel liegt als PEM/SPKI vor
(`passkeys.public_key_encoding = 'pem-spki'`, `passkeys.cose_algorithm`). UserHandle =
`passkeys.user_handle`, UTF-8-Bytes des UUID-Textes des Kontos; der Server vergleicht
die gelieferten Bytes exakt mit der gespeicherten Spalte und mit dem Konto der
Credential-ID (Schreibweise des UUID-Textes: OFFEN, siehe `migration-mapping.md`).
Zaehlerregel `(alt==0 && neu==0) || neu>alt` per bedingtem UPDATE
(`sign_count < neu OR (sign_count=0 AND neu=0)`); 0/0 erkennt kein Replay, dieses
verhindert nur die einmalige Challenge. Challenge (`auth_challenges`, purpose
passkey-login/passkey-register): einmalig, an Session und Zweck gebunden, Lebensdauer
hoechstens 120 s (DB-CHECK `expires_at <= created_at + 120 s`), `consumed_at` bei
jedem Pruefversuch gesetzt, nur SHA-256 gespeichert. RSA-Schluessel unter 2048 Bit
werden abgelehnt (Bestandsverteilung unbekannt). Neuregistrierung (CBOR/COSE nach
PEM) ist nicht Teil dieses Vertrags (spaeteres Paket).

Credential-ID, öffentlicher Schlüssel, unverändertes UserHandle, Zähler und
PRF-bezogene Zuordnung/Wrappingmetadaten migrieren; keine Neuregistrierung
voraussetzen. Der Server erhält kein PRF-Ergebnis, keinen entschlüsselten
Kontoschlüssel und keine Recovery-Passphrase. Passkeylogin bedeutet nicht, dass
der Browser Datenschlüssel bereits entsperrt hat. Browser-/PRF-Kompatibilität und
unveränderte Schlüsselhüllen sind erst in P3 nachzuweisen.

Beschlossen mit ADR 0022 (P11-G): Der serverseitig registrierte Listener entscheidet,
nicht Host, Header oder Client-IP. Intern genügt ein Passkey mit zwingender User
Verification; `FORM_INTERNAL_SECOND_FACTOR=1` verlangt auch dort das Passwort.
Öffentlich gemountetes Dashboard verlangt immer Passkey plus Passwort. Jeder
Sitzungstoken wird mit einer festen Listener-Domäne gehasht (v2); ein interner
Token gilt öffentlich auch bei gleicher Origin nicht. Die Policy wird zusätzlich
beim Sitzungszugriff geprüft. Alte v1-Sitzungen sind damit ungültig.
Fresh-Login gilt standardmäßig 30 Minuten (Einstellung `auth.freshLoginMinutes`, 1–120, im UI
änderbar; frühere feste Grenze: 5 Minuten). Beschlossen mit ADR 0037: Die PWA fragt bei
`reauthentication_required` auf der aktuellen Seite einen UV-Passkey desselben Kontos ab
(`POST /auth/reauth/options|verify`, Challenge-Zweck `fresh-auth`, an Sitzung und Konto
gebunden, einmalig, 120 s); Erfolg setzt nur `authenticated_at` dieser Sitzung, ohne
neuen Token, ohne Rotation und ohne Rechteänderung, Audit `auth.reauth`. Verlangt der
Listener Passwort/Zweitfaktor, lehnt der Server mit 409 `second_factor_required` ab und
die PWA führt wie bisher den vollständigen Login erneut aus (ebenso ohne Passkey-Support
im Browser). Frische gilt für verändernde und sensible Aktionen; ohne Frische lesbar sind
`GET /migration/jobs` und `GET /settings` (Liste und Begründung in ADR 0037). Zählervergleich
bleibt atomar; Bestandsausnahme 0→0 für synchronisierte Passkeys bleibt erhalten.
Passwort bei Kontoanlage intern optional (leerer Hash = kein Passwort), öffentlich
bzw. mit internem Zweitfaktor erforderlich. Eigenes Passwort unter `PUT /me/password`
mit frischer Sitzung setzen; andere Sitzungen werden widerrufen. Enrollment und
Ersatz-Link verleihen weiterhin keine Sitzung und bleiben einmalig/befristet.
Credentialentfernung muss zugehörige Schlüssel-Wraps und letzten Datenzugang
berücksichtigen. Passwortreset stellt Datenzugang nicht automatisch wieder her;
Reset-/Recoveryverfahren und Notfallzugang sind **OFFEN**.

## DB-Sitzungen und CSRF

VORGESCHLAGEN: opake, zufällige 256-Bit-Sitzungskennung im Cookie, nur Hash in DB.
DB-Datensatz: Konto, Zustand, Erstellung, letzter Zugriff, absolute/idle Frist,
Authentifizierungsverfahren/-zeit, Rechteversion, CSRF-Bindung und Widerruf.
Challenge-/Faktor-Zustand ebenfalls in DB; kein replikaeigener Sicherheitszustand.
Cookie `__Host-admin_session`, Secure, HttpOnly, SameSite=Lax, Path=/, kein Domain-
Attribut. Admin-Origin liefert HTTPS; Kundenhosts bekommen keine Admin-Cookies.
Serverfristen gelten auch bei länger gültigem Browsercookie.

Bei Login, Faktorabschluss und Privilegwechsel Sitzung rotieren, alte Kennung
widerrufen. Logout POST, CSRF und DB-Widerruf; Browser sperrt Schlüsselablage und
entfernt sensible lokale Zustände. Eigenes Konto darf andere Sitzungen widerrufen.
Kontosperre widerruft Sitzungen, manuelle Tokens, Grants und Refreshfamilien;
Rollen-/Zuordnungsentzug wirkt sofort durch aktuelle DB-Rechteprüfung. Keine
unbegrenzten Replikacaches. Passwort-/Faktoränderung widerruft andere Sitzungen;
konkrete Tokenwiderrufsfolge bei Passwortwechsel ist **VORGESCHLAGEN: alle**.

Synchronizer-CSRF-Token pro DB-Sitzung, auch vor Login. `GET /auth/session` liefert
CSRF und nicht sensible Zustandsdaten, erzeugt bei Bedarf anonyme DB-Sitzung.
Jede cookiebasierte Mutation inklusive Login, Faktorprüfung, Logout und
OAuth-Zustimmung braucht `X-CSRF-Token` plus exakte Admin-Origin-Prüfung.
OAuth-Formular darf einen an die Sitzung gebundenen versteckten CSRF-Wert nutzen.
Kein mutierendes GET, keine Freigabe durch SameSite allein. Fehlender CSRF zählt
nicht als falsches Passwort/TOTP, allgemeines Ratenlimit zählt weiter. REST mit
Bearer akzeptiert keine parallele Sitzung; bei beiden Autharten 400. Bearer-
Anfragen haben keine Cookie-CSRF-Ausnahme für nachgelagerte menschliche Aktionen.

`Cache-Control: no-store` für Anmeldung, Sitzungen, Chiffrate, Tokens und sämtliche
Verwaltungsantworten; PWA speichert nur statische Assets. CORS für Verwaltung
standardmäßig aus, keine Wildcard mit Credentials. Fetch-Metadata nur ergänzend.

## Konkrete Schwellen – sämtlich VORGESCHLAGEN

| Zähler / Frist | Vorschlag und Auslösung |
| --- | --- |
| Passwortfehlversuche je Konto | 5 innerhalb 15 min: Sperre 15 min ab fünftem Fehler |
| Passwortfehlversuche je Client-IP | 30 innerhalb 15 min: Sperre 15 min; unabhängig vom Kontozähler |
| Backoff je Konto und IP | Ab drittem Fehler 1s, dann 2s, 4s … maximal 60s; größeres aktuelles Limit gilt |
| TOTP / Zweitfaktor | 5 Fehler je Konto und IP/15 min: 15 min Sperre; keine Umgehung durch neue Sitzung |
| Adminzugänge einschließlich UI, Auth, REST, MCP/OAuth-Metadaten | 120 Requests/IP/60s und nach Login 300/Konto/60s; jeder Request zählt genau einmal je anwendbarem Budget |
| Login/Challenge/Tokenendpoint zusätzlich | 10 Requests/IP/60s; gilt vor Kontoauflösung |
| Tests, Debugstart, Exporte, Resend zusätzlich | 10 Starts/Konto/60s; fachliche Batchgrenzen bleiben separat |
| Anonyme/Faktor-Zwischensitzung | Absolut 5 min, keine Verlängerung durch Polling |
| Authentifizierte Sitzung | Idle standardmäßig 120 min (Einstellung `auth.sessionIdleMinutes`, 5–720, im UI änderbar; früher fest 30 min), absolut 12h; „angemeldet bleiben“ zunächst keine Fristverlängerung |
| Frische Authentifizierung für H-Aktionen | Höchstens `auth.freshLoginMinutes` (Standard 30, 1–120 min); zweckgebundene Veröffentlichungsgenehmigung siehe MCP-Vertrag |
| Bestätigungsfehlversuche | 5/Konto und IP/15 min, danach 15 min Sperre |

Sliding Windows und `nextAllowedAt` in DB atomar aktualisieren; keine blockierenden
Sleeps im Webworker. Aufruf während Sperre erzeugt keinen Hashversuch und
verlängert nicht dauerhaft die Sperre. Erfolg setzt nur den Kontofehlerverlauf
zurück, niemals das IP-Budget oder normale Requestlimits. Nach Ablauf altert das
Fenster aus; kein dauerhafter Angriffssperrzustand. Bei unbekanntem Konto einen
begrenzten, pseudonymisierten Bezeichnerzähler verwenden; Speicherflut begrenzen.
Bei DB-Ausfall kein lokaler unlimitierter Fallback (503). Gleichzeitige Requests
müssen Grenzüberschreitungen serialisieren. 429 plus `Retry-After` in Sekunden,
401 generisch für ungültige Anmeldedaten, 403 für CSRF, 400 für Syntax/Unbekanntes.
Diese Schwellen ersetzen keine Lastmessung/NAT-Bewertung und sind keine
Übernahme der anders arbeitenden Alt-IP-Bannlogik aus A §6.

## Persistenznachtrag H03 — VORGESCHLAGEN (27.10.2026)

Maßgeblicher technischer Entwurf: `../data/schema-entwurf.sql`, Tabellen
`sessions`, `auth_challenges`, `totp_replay_state`, `publication_confirmations`.
API-Session-ID ist `sessions.id` (öffentliche UUID); Cookie enthält ein separat
zufälliges 256-Bit-Token, ausschließlich dessen Hash wird gespeichert. Anonym
ist account_id NULL, factor_pending bindet ein Konto ohne Vollzugriff.
Authentifizierte Sitzung benötigt Methode, authenticated_at und Rechteversion;
Rechte werden dennoch bei jeder Operation aktuell geprüft. Faktorzeiten sind
kein Entschlüsselungsnachweis. Fristen bleiben die oben vorgeschlagenen Werte.

Rotation bei Login/Faktorabschluss/Privilegwechsel erzeugt neue ID, Token und
CSRF-Bindung und widerruft die alte Zeile atomar (replaced_by). Alte Challenges
und Publikationsbestätigungen widerrufen, niemals auf die neue Sitzung kopieren.
Logout/Kontosperre sperrt dieselben Zeilen; Ablauf wird bei jedem Gebrauch über
DB-Zeit geprüft. Keine Prozessspeicher-Ausnahme zwischen Replikas.

Challenge/Enrollment bindet Session, Zweck, Faktor und gegebenenfalls Konto;
Faktor-Challenges binden zusätzlich die aktuelle factor_revision.
WebAuthn speichert SHA256 der zufälligen Challenge, Enrollment nur eine sichere
Secretreferenz. MFA-Provider/Zielformat bleibt OFFEN M05/K11, kein Klartextfeld.
Bei zulässigem Prüfversuch Challenge unter Zeilensperre einmalig beanspruchen
und consumed_at dauerhaft setzen, auch bei anschließendem Prüfungsfehler.
Erfolgszustand wird erst nach vollständiger Prüfung gesetzt; verlorener Prozess
nach Verbrauch verlangt neue Challenge. CSRF-/Sitzungs-/Zweckfehler erlauben
keinen Faktorabschluss. Ablauf, Widerruf und consumed_at schließen Wiedergebrauch
aus. Ein DB-Rollback darf einen fehlgeschlagenen Versuch nicht reaktivieren.

TOTP vergleicht den konkret akzeptierten Schritt unter Kontosperre gegen
`totp_replay_state.last_accepted_step`; nur strikt größerer Schritt derselben
factor_revision darf atomar gespeichert werden. Vergleich, Faktorabschluss und
Sitzungsrotation koordinieren; ein verbrauchter Schritt bleibt auch nach
Antwortverlust verbraucht. Neue Sitzungen umgehen den Replayzustand nicht.
Enrollment/Ersetzen erhöht die Faktorrevision atomar, startet Replayzustand mit
dem Aktivierungsschritt und widerruft alte Faktor-Challenges. Revisionen werden
nicht zurückgesetzt oder wiederverwendet. Zusätzlich gelten aktuelle Limits.

Publikationsbestätigung bindet Sitzung, Konto, Kunde, Formular, Entwurf,
Revision, Kandidatenhash, authentifizierten Zeitpunkt und Ablauf. Nur gültige
volle menschliche Sitzung, CSRF und aktuelle Rechte dürfen sie erzeugen.
Verbrauch sperrt Bestätigung, Sitzung, Kandidat und Aktionsledger; alle Bindungen,
Frische und Rechte erneut prüfen. Releaseerzeugung, consumed_at/release_id,
Audit und Ledgerabschluss gemeinsam committen. Rücknahme setzt keinen Verbrauch
frei. Gleicher Idempotenzkey nach Antwortverlust liest denselben Release aus
dem Ledger (siehe `../data/abbildung.md`); neue Keys mit verbrauchter Bestätigung
werden abgelehnt. Draftpersistenz bleibt bestehender P2-Entwurf; Dienst muss
Revision/Hash unter derselben Sperre prüfen, kein freier Clientnachweis.
Feinrechte, MFA-Pflicht und konkrete Fristen bleiben OFFEN bzw. VORGESCHLAGEN.
