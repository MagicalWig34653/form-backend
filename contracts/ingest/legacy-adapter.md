# Befristeter Docker-Adapter und Legacyvalidierung

Stand 27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

**BESCHLOSSEN ADR 0004 H11:** Docker-Kompatibilitätsadapter für v1-Header als
begrenzte Ausnahme zu ADR 0001; kein Altdecoder im Kern. Die historischen Bytes
stehen in `../crypto/migration.md`. Formularinhalte in :1/CBC werden dadurch
nicht für den Laufzeitkern freigegeben.

## Vertrauensgrenze (technischer Vertrag VORGESCHLAGEN)

Alt-SDK → TLS/Proxy → isolierter Docker-Adapter → TLS mit gegenseitiger
Dienstauthentifizierung → regulärer neuer Ingest. Der Adapter bekommt nur
formularbezogene v1-Header-Schlüssel und eigene formularbezogene Ed25519-
Signieridentität, niemals Kunden-/Kontodatenschlüssel. Globale Alt-Schlüssel
werden nicht als Mehrformularfallback übernommen. SDKs mit ausschließlich
globalem Schlüssel müssen vor Freigabe formularbezogen provisioniert werden;
unlösbare Bestandszuordnung bleibt **OFFEN**, kein verdeckter Bypass.

Adapter prüft Formularallowlist, Host/Origin, alte UA-/IP-Hülle einschließlich
MAC; gibt keinen Klartext vor erfolgreicher Prüfung aus. Headerdarstellung und
AES-Anpassung benötigen K01-Kreuzvektoren. Der historische ungeschützte IV ist
kein starker Herkunftsnachweis; Adapterannahme muss ausdrücklich je Formular
freigegeben sein. Keine stärkere Garantie als der geprüfte Altvertrag behaupten.
Er wandelt Signale in formularbezogene neue Header um und signiert die
unveränderte kanonische POST-/Dateidarstellung als registrierter Adapter.
Der Kern prüft die neue Signatur und denselben Fachvertrag, kein Vertrauen in
einen frei gesetzten `legacy=true`-Header. Adapterzugänge sind nur auf dem
authentisierten Dienstpfad erlaubt. Clientgelieferte interne Vertrauensheader
am Proxy entfernen; direkter Zugriff kann diesen Pfad nicht wählen.
Originale SDK-Signaturen nicht fälschlich als Adapter-Signaturen ausgeben.

Beide Seiten begrenzen Bytes/Dateien/Raten; gemeinsame Idempotenzidentität
erhalten; v1-Textantworten und Skriptaliase am Adapter übersetzen. Kern bleibt
für reguläre v2-SDKs erreichbar. Kein Logging von Signalheadern, Klartext,
Schlüsseln; Audit nur Formular, Adapteridentität, Ergebnis und Zähler.

Laufzeit **VORGESCHLAGEN: 90 Tage ab formularbezogener Aktivierung**, vom Nutzer
nicht bestätigt. Ohne ausdrücklich gesetztes Ablaufdatum keine Aktivierung;
kein Default von 90 Tagen. Aktivierung, `expires_at`, `revoked_at` und sichere
Schlüsselreferenzen in `legacy_adapter_bindings`; aktuelle Freigabe vor jedem
Request prüfen. Ablauf/Widerruf sperrt Dienstzugang und Adapterannahme sofort.
Abschaltung: SDK-Umstellung nachweisen, Adapterzugänge/Signierkeys und
Header-Keyreferenzen widerrufen, Proxyroute entfernen, Adapter/Secrets entfernen,
Negativprobe direkter alter Header und alter Adapteridentität. Keine Verlängerung
ohne ausdrücklich dokumentierte Freigabe; keine Betriebsfreigabe durch diesen Text.

## M02: Auswahl durch gespeicherten Formularvertrag

Neue Formulare: `validation_profile=typed-v1`; Regeln in `../flow/form.schema.json`.
Altformulare: `validation_profile=legacy-v1` und unveränderliche referenzierte
Adapterdefinition (`legacy_adapter_ref`); kein automatisches Uminterpretieren
als typisiertes Formular. Das ist getrennt vom befristeten Headeradapter: eine
Header-SDK-Umstellung ändert die Fachsemantik des Formulars nicht.

Altes Verhalten laut Review S13/S15: Pflicht via `isset`, leere Strings
überspringen Typ-/Regelprüfung, PHP-tolerante Typ-/Boolkonvertierung und bisherige
erste Datei erhalten; keine neue Mehrdateiannahme oder unbekannte-Feld-Ablehnung
ohne belegten Adaptervertrag. Spezialhandler separat referenzieren. Nach Signatur
technische Felder prüfen und abtrennen, danach die passende Fachvalidierung.
Legacydefinitionen sind kein ungeprüfter ausführbarer PHP-Import.

**BESCHLOSSEN ADR 0005 D6:** Scannerfehler lässt durch (nur Treffer 451; Scannerfehler
allein verhindert Annahme nicht, nie 503; Status erhalten). Der Bewerbungshandler
behält bei Zustimmung ungleich String `true` → 418 und Proxyzweigfehler → 424. Nicht
auf alle Formulare ausweiten. Eine Verschärfung (503, Ersatzcodes) ist unbeschlossen.
Vollständige Feld-/Bool-/Spezialhandlerfixtures und technische Fehlerpriorität
bleiben Prüfauftrag; die Auswahlentscheidung ist geschlossen, Adapterimplementierung
und unabhängige Paritätsabnahme fehlen.

## Vertragsrunde 3 — R03 Adapteridentität und Headeranschluss (VORGESCHLAGEN)

Stand 28.10.2026. Die **Wahl, ob der Adapter überhaupt eine eigene
Signieridentität und mTLS-Dienstidentität erhält**, ist eine Sicherheits-/
Betriebsentscheidung des Nutzers (Empfehlung: ja); der folgende Vertrag setzt
sie als Option A um und ist ohne Bestätigung nicht aktivierbar. Siehe
`docs/handoffs/vertragsrunde-3-offen.md`.

**Identitäten.** Pro `legacy_adapter_bindings`-Zeile (Formular + Adapter) gibt es
(a) eine Dienstidentität `adapter_identity` mit mTLS-Clientzertifikat
(`service_cert_sha256`-Pin) und (b) ein eigenes Ed25519-Signierregister
`adapter_signers` (Generation, current/previous mit Ablauf, Widerruf). Der native
SDK-Slot (`form_protocol_keys purpose='ed25519'`) ist davon getrennt; beide
Sätze können gleichzeitig aktiv sein, Rotation und Widerruf sind unabhängig.
Der Adapterschlüssel wird vom Adapter selbst erzeugt; nur der öffentliche Schlüssel
wird beim Aktivieren registriert. Berechtigung zum Aktivieren/Widerrufen:
Vorschlag `system.manage` mit menschlicher Bestätigung (Vertrauensgrenze);
Alternative `key.manage` im Formularscope; Wahl offen.

**Dienstkanal.** Der Kern bietet einen separaten Listener (nur interne Adresse,
mTLS) mit denselben Pfaden `/api/v2/submit/` und `/api/v2/form/`. Vom
**öffentlichen** Listener wird der Adapterpfad nie bedient; die unten genannten
`X-Kubus-Adapter-*`/`X-Kubus-Attested-*`-Header werden dort ersatzlos entfernt
bzw. die Anfrage mit 400 abgelehnt. Die Bindung wird allein aus dem
Zertifikat-Pin gelöst (`legacy_adapter_bindings`), nicht aus einem Header.

**Header des Adapters an den Kern (abschließend):**

| Header | Inhalt | Pflicht |
| --- | --- | --- |
| `X-Kubus-Adapter-Binding` | UUID der Bindung, muss der zertifikatsaufgelösten entsprechen | ja |
| `X-Kubus-Timestamp` | Unixsekunden, ±300 s | ja |
| `X-Kubus-Signature` | Base64 Ed25519 (64 Byte) über den Text unten | ja |
| `X-Kubus-Attested-Client-Ip` | genau eine syntaktisch gültige IP, nur nach erfolgreicher v1-Signalprüfung; **schwaches Signal**, siehe Vertragsrunde 4 A3 | optional |
| `X-Kubus-Attested-Origin` | Originalwert des `Origin`-Headers (Zeichenklasse siehe Runde 4 A4) | optional |
| `Idempotency-Key` | unverändert vom Alt-SDK, falls vorhanden; **ab Runde 4 im Signaturtext gebunden** | optional |

Die v1-Signale (`CLIENTUA-ENCRYPT`, `CLIENTIP-ENCRYPT`) und deren MAC werden
ausschließlich im Adapter geprüft und nie weitergereicht. Fehlt das Signal oder ist
es ungültig, wird `X-Kubus-Attested-Client-Ip` weggelassen; der Kern behandelt
das wie die reguläre Route ohne IP-Signal (Peer-IP des Adapters wird nie als
Client-IP für Limits verwendet).

**Signaturtext** (UTF-8, LF als Zeilentrenner, kein abschließender LF; Namespace
`KUBUS-ADAPTER-SIGN-1`, **VORGESCHLAGEN**, Kryptoreview erforderlich; in
Vertragsrunde 4 um Idempotency-Key erweitert und Zeilen neu geordnet, damit die
letzte Zeile immer ein Pflichtwert ist). Es gilt der Wertkanon aus
`../crypto/signatur.md` (Abschnitt Vertragsrunde 4, Kanon):

```text
KUBUS-ADAPTER-SIGN-1
POST
<path-literal>?f=<formId lowercase>
<adapter-binding-uuid lowercase>
<timestamp>
<effective idempotency key oder leere Zeile>
<attested client ip oder leere Zeile>
<attested origin oder leere Zeile>
<bodyHash, 64 kleine Hexzeichen, wie signatur.md>
```

`<path-literal>` ist die Routenkonstante `/api/v2/submit/` bzw. `/api/v2/form/`
(mit abschließendem Slash, wie die Wirepfade des Dienstlisteners und der native
Text), nie die Rohquery oder der Rohpfad der Anfrage. `bodyHash` ist derselbe
`request_digest` der PHP-äquivalenten Struktur, die der Adapter aus dem Alt-Request
gebildet hat. Der Kern berechnet ihn selbst und vergleicht. Die Signatur bindet
damit Bindung, Pfad, Zeit, Idempotency-Key, Inhalt, Client-IP und Origin; ein
kompromittierter öffentlicher Pfad kann sie nicht erzeugen. Ein abwesender Wert
ist eine **leere Zeile** (kein `-`, das ein echter Originwert sein könnte).

**Prüfreihenfolge im Kern:** (1) mTLS-Pin → Bindung, nicht widerrufen, nicht
abgelaufen (`activated_at ≤ jetzt < expires_at`) → sonst 403; (2) Formular gehört zur
Bindung und `form_versions.transport_policy` ist nicht `required`; (3) Signatur
gegen `adapter_signers` (current oder previous nicht abgelaufen, strikte
Ed25519-Prüfung nach `signatur.md`); (4) Zeitfenster; (4a) Replayreservierung in
`adapter_replays` (Runde 4 A1; erst nach gültiger Signatur, sonst 409);
(5) Digest/Idempotenz und reguläre Fachprüfung. Native Schlüssel werden auf dem
Adapterpfad nie probiert, Adapterschlüssel auf dem öffentlichen Pfad nie.
Einsendungen merken `signer_kind='legacy-adapter'`, Generation und Bindung.

**Aktivierung/Abschaltung.** Aktivierung verlangt ein ausdrücklich gesetztes
`expires_at` (kein Default; 90 Tage bleibt ein unbestätigter Vorschlag), Registrierung des
Public Keys und des Zertifikat-Pins, menschliche Bestätigung. Widerruf
(`revoked_at` oder Signer `revoked`) wirkt sofort für den nächsten Request.
**Abnahme (nicht ausgeführt):** gleichzeitiger nativer SDK- und Adapterbetrieb;
Rotation des einen ohne Einfluss auf den anderen; sofortiger Adapterwiderruf;
Adaptersignatur am öffentlichen Pfad abgelehnt, native Signatur am Adapterpfad
abgelehnt; manipulierte Attested-Header; Pin eines fremden Zertifikats.

## Vertragsrunde 4 — Kryptoreview-Befunde A1–A7 (VORGESCHLAGEN)

Stand 30.10.2026, Bezug `docs/paritaet/review-krypto-adapter.md`. Nichts ausgeführt,
keine Vektoren gerechnet. A2 (Authentisierungsstufe) ist **nicht entschieden**:
siehe `docs/handoffs/vertragsrunde-4-offen.md`.

**Fakt zu A2 (Altcode lesend geprüft, Altprojekt nicht geändert).** Das Alt-SDK
`providers/Clients/Backend.php` (v1) sendet an `getFormData.php` und den Endpoint
nur die Header `CLIENTUA-ENCRYPT`, `CLIENTIP-ENCRYPT` und `CLIENTGCLID` (Zeilen
84–90 für `getFormData.php?z=`, 181–193 für `endpoint/?f=`) und **keinen** `X-Kubus-Signature`/`X-Kubus-Timestamp`. Der
Ed25519-Signaturheader existiert nur im v2-Client `providers/Clients/BackendV2.php`
(Zeilen 380–388; Zeile 299 ist der Rotationstext); serverseitig rufen ausschließlich `www/api/v2/form/index.php`
und `www/api/v2/submit/index.php` `AnfrageSignatur::pruefeV2OderBeende` auf. Die
v1-Routen prüfen keine Body-Signatur. Daraus folgt: Es gibt für v1-Requests keine
ursprüngliche SDK-Signatur, die der Adapter prüfen könnte. Die Authentisierung des
Alt-Requests besteht ausschließlich aus den v1-Header-MACs (im Altclient mit fest einkompilierten Schlüsseln, vgl. Altprojekt `docs/datenschutz/findings/PRIV-001-hartcodierte-client-schluessel.md`; formularbezogene Schlüssel sind erst Ergebnis der Provisionierung nach diesem Vertrag), die
weder Body noch Zeitstempel abdecken (`aes256Encode`: IV‖HMAC(ct)‖ct, kein Zeitfeld).
Die Aussage „originale SDK-Signaturen“ (oben) gilt nur für v2-SDKs, die den Adapter
nicht benötigen. Optionen und Empfehlung stehen in der Entscheidungsvorlage; bis
zur Entscheidung gilt der Adapterpfad als **schwächere Stufe als der native Pfad**
und bleibt nicht aktivierbar.

**A1 Replay und Idempotency-Key.** (a) Der effektive `Idempotency-Key` (PHP-`trim`,
1–190 Byte, sonst ungültig = abwesend, wie `README.md` Idempotenz) steht im
Signaturtext. (b) Replayregister `adapter_replays`
(`../data/schema-entwurf.sql`): Schlüssel `(binding_id, SHA-256 des vollständigen
Signaturtexts)`; **nie** über Signaturbytes (A7). Reservierung atomar replikaübergreifend
nach gültiger Signatur und vor jeder Nebenwirkung; zweite identische Anfrage →
`409 replay` ohne Nebenwirkung. Retention: `expires_at >= timestamp + 300 s + 60 s
Uhrtoleranz` und mindestens 600 s ab Reservierung (Fenster ±300 s, siehe
`../crypto/transport.md` T2); Löschung nie vor `expires_at`. Bei DB-Ausfall 503.
Ein legitimer Retry des Adapters signiert mit frischem Zeitstempel und demselben
Key neu und trifft die normale Ingest-Idempotenz, nicht das Replayregister.
Prüffall: gleiche signierte Anfrage zweimal; Anfrage mit verändertem/entferntem
Key (Signatur ungültig → 403); Löschjob zwischen Grenzzeit +299 s.

**A3 Signalstärke.** `X-Kubus-Attested-*` bleibt als Headername, bedeutet aber
nur „vom Adapter aus einem v1-Signal gelesen“. Das v1-Signal hat keinen Zeitstempel
und keinen IV-Schutz (Fakt oben); ein mitgeschnittener Header ist beliebig
wiederverwendbar. Folgen: Die Attested-IP darf nicht als alleiniger Schlüssel für
Rate-Limits/Sperren des Adapterpfads dienen (Sperre unbeteiligter Nutzer durch
Header-Pool); Limits des Adapterpfads zusätzlich pro Bindung. Die IP wird nicht
persistiert (ADR 0003). Wahl, ob die Attested-IP überhaupt benutzt wird, ist Teil
der A2-Vorlage.

**A4 Textkanon.** Pfadliteral, Timestamp, UUID-Lowercase und Placeholder wie oben und
in `../crypto/signatur.md`. `Attested-Origin`: nur ASCII 0x21–0x7E, höchstens 255 Byte,
sonst Anfrage am Adapter mit 400 abgelehnt (kein LF, kein NUL); ein leerer oder
fehlender Header ergibt die leere Zeile. `Attested-Client-Ip`: genau eine
syntaktisch gültige IPv4/IPv6 in kanonischer Textform (Kleinschreibung, kein Zone-
Index). Binding-UUID und formId lowercase; Großbuchstaben werden abgelehnt, nicht normalisiert.

**A5 Umgebungs-/Registereindeutigkeit.** Der öffentliche Adapterschlüssel ist
über alle `adapter_signers`-Zeilen eindeutig (`UNIQUE (public_key)`, unabhängig vom
Status) und darf nicht zugleich in `form_protocol_keys(purpose='ed25519')` stehen
(Prüfung in derselben Aktivierungstransaktion; kein DB-Constraint tabellenübergreifend
möglich). Staging und Produktion dürfen weder Adapterschlüssel noch Bindungs-UUID
noch mTLS-Pin teilen; ein Adapterschlüssel gilt in genau einer Umgebung. Eine
Umgebungskennung im Signaturtext ist nicht nötig, solange diese Eindeutigkeit
bei der Aktivierung erzwungen und im Betrieb geprüft wird.

**A6 Widerruf, Cache, Pin-Rotation.** Bindungs- und Signerstatus werden pro Request
aus der Datenbank gelesen (kein Prozesscache; ein Cache ist nur mit sofortiger
replikaübergreifender Invalidierung zulässig, sonst TTL 0). Pin-Überlappung:
`legacy_adapter_bindings.service_cert_sha256_next` (NULL oder zweiter gültiger
Pin); beide Pins gelten, bis der alte durch einen bestätigten Aktivierungsschritt
entfernt ist. Hinweis: Der Vorgängerschlüssel bleibt bis `valid_until` gültig. Bei
Verdacht auf Schlüsselkompromittierung genügt Rotation nicht; der Signer (auch der
Vorgänger) wird auf `revoked` gesetzt.

**A7 Ed25519-Strenge.** Gilt für alle drei Signaturtexte: siehe
`../crypto/signatur.md` (strikte Verifikation, Negativvektoren, Replay nie über
Signaturbytes).

## Vertragsrunde 3 — M02: vollständige Adapterdefinition

Die versionierte Definition, PHP-Typ-/Leerwert-/Boolsemantik, Spezialhandler und
synthetische Fixtures stehen in [legacy-validation-v1.md](legacy-validation-v1.md),
[legacy-validation.schema.json](legacy-validation.schema.json) und
[legacy-validation-fixtures.json](legacy-validation-fixtures.json). Scannerfehler-Durchlass
und 418/424 gelten verbindlich (ADR 0005 D6).
