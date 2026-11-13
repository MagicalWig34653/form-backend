# Symmetrische Transporthülle (H05)

Stand 27.10.2026. SPDX-License-Identifier: AGPL-3.0-only.

**BESCHLOSSEN ADR 0004:** eigene zusätzliche symmetrische Transporthülle.
Sie ist unabhängig von Speicherung und CEK-Wrap. Neue Speicherung bleibt
`hpke-v2`; `sym-v2` als auswählbares Speicherprofil bleibt gesperrt. `wrap=sym`
für bestehende Objekte/Nachschutz ist weiterhin der Paketvertrag, kein Transport.
Der folgende neue Wirevertrag ist **VORGESCHLAGEN**, vor Implementierung durch
synthetische PHP-/Swift-Kreuzvektoren und unabhängiges Kryptoreview abzunehmen.

## Wireformat und Zwecke

POST `/api/transport/v1/submit/?f=<uuid>` oder
`/api/transport/v1/form/?f=<uuid>`, ausschließlich TLS und JSON gemäß
`../ingest/ingest.openapi.yaml#/components/schemas/TransportEnvelope`.
Pfad für Signatur/AAD ohne abschließenden Slash (Literal aus der Routenkonstante,
`/api/transport/v1/submit` bzw. `/api/transport/v1/form`, siehe
`signatur.md` Vertragsrunde 4), Query exakt `?f=<uuid>` (Kleinbuchstaben-UUID).
Keine zusätzliche Query, keine Skriptaliase für diesen neuen Vertrag.

Hülle: `version=transport-v1`, `formId`, `keyVersion` (JSON-Integer `^[1-9][0-9]{0,18}$`, kein Exponent/Bruch/führende
Null), `requestId` (Kleinbuchstaben-UUID), `timestamp` (dezimaler Unixsekundenstring
`^[1-9][0-9]{0,11}$`),
`nonce` (12 Byte), `ciphertext` (mindestens 16 Byte, Tag angehängt).
Binärwerte: kanonisches Standard-Base64 mit Padding; keine Leerzeichen.
Unbekannte Felder, doppelte JSON-Schlüssel, falsche Längen ablehnen.
`formId` muss dem Queryformular entsprechen; Kundenbezug ausschließlich aus DB.

AES-256-GCM mit unabhängig zufällig erzeugtem formularbezogenem 32-Byte-
Transportschlüssel, 12-Byte-CSPRNG-Nonce und 16-Byte-Tag. Keine Ableitung aus
Header-, Signatur-, Konto- oder Kundendatenschlüsseln. Keine Noncewiederverwendung
unter demselben Schlüssel; bei unklarem Senderzustand vor Weiterbetrieb rotieren.
AAD exakt ASCII, LF zwischen den Zeilen, kein abschließender LF:

```text
KUBUS-TRANSPORT-1
POST
<path>?f=<uuid>
<formId>
<keyVersion>
<requestId>
<effective idempotency key oder leere Zeile>
<timestamp>
```

Die Idempotency-Zeile (Vertragsrunde 4, T1) ist der effektive `Idempotency-Key` nach
`signatur.md` (getrimmt, 1–190 Byte, sonst leere Zeile); die letzte Zeile bleibt der
Pflichtwert `timestamp`. Der Header `Idempotency-Key` der Anfrage muss nach derselben
Regel genau diesen Wert ergeben, sonst 403 (Hülle mit verändertem Header). Retry mit
frischer Hülle und gleichem Key bleibt möglich.

Ed25519-Header wie im Signaturvertrag; hier neuer Signaturtext (kein Ersatz
der PHP-Kanonisierung auf den bestehenden Routen), LF, kein abschließender LF:

```text
KUBUS-TRANSPORT-SIGN-1
<AAD-Text>
<base64 nonce>
<lowercase SHA256(ciphertext einschließlich Tag)>
```

`X-Kubus-Timestamp` muss exakt `timestamp` entsprechen. Vor Entschlüsselung
registrierten aktuellen/gültigen Vorgänger-Public-Key (strikte Ed25519-Prüfung nach
`signatur.md`) und ±300-Sekundenfenster prüfen. Vor Hüllenauthentifizierung keine Entschlüsselung/Nebenwirkung; Fehler
einheitlich 403 ohne Kryptodetail. Keine automatische unverschlüsselte Wiederholung
bei Tag-/Signaturfehler. Signaturausnahmen gelten hier nicht (VORGESCHLAGEN).

Innerer UTF-8-JSON-Body gemäß `TransportPayload`: `fields` ist die ursprüngliche
PHP-kompatible String-/Listen-/Objektstruktur, `files` eine geordnete Liste aus
`field`, `name`, `type`, `content` (Base64-Rohbytes). Formabruf hat keine Dateien.
Keine Normalisierung vor Authentifizierung; nach Öffnen Größen-/Datei-/Bot-/
Validierungsregeln des gewählten Formularadapters anwenden. Technikfelder danach
abtrennen. Derselbe Fachpfad wie regulärer Ingest; kein zweiter Versanddienst.
Antworten sind reguläre v2-JSON-Antworten über TLS; keine erfundene Antwortnonce.
**OFFEN (nicht entschieden, Review T3):** Antwortauthentisierung bzw. ausdrückliche
Erklärung als außerhalb des Schutzziels; siehe
`docs/handoffs/vertragsrunde-4-offen.md`. Bis dahin gilt: `offered` bietet gegen einen
aktiven Angreifer zwischen TLS-Ende und Kern keinen Downgradeschutz, nur `required`.

## Schlüssel, Replay und Persistenz

`form_protocol_keys.purpose=transport` speichert nur `secret_ref`, Generation,
Status und Ablauf. Provisionierung über gesondert authentisierten administrativen
Kanal an genau das Formular-SDK; niemals im öffentlichen Formabruf, Paketexport
oder Log. Sicherer Provider/Provisionierungsablauf **OFFEN**; bis Abnahme gesperrt.
Rotation: neue Generation current, alte previous mit ausdrücklichem Ablauf,
Widerruf sofort. Überlappungsdauer **OFFEN**, kein unbefristeter Vorgänger.

Nach gültiger Signatur/Tagprüfung `(formId,keyVersion,requestId)` und Nonce
replikaübergreifend atomar in `transport_replays` reservieren. Gleiche Nonce oder
requestId erneut: 409, keine Nebenwirkung. Eindeutigkeit getrennt:
`(form_id,key_version,request_id)` und `(form_id,key_version,nonce)`.
**Retention (VORGESCHLAGEN, T2):** Eine Hülle mit `timestamp = jetzt+300` bleibt bis
`jetzt+600` annehmbar. `expires_at` = `max(timestamp + 300 s, Reservierungszeit + 300 s)
+ 60 s Uhrtoleranz`, also mindestens 600 s ab Reservierung für Hüllen am oberen
Fensterrand; Löschung nie vor `expires_at` und nie nach Eingangszeit berechnet.
Prüffall: Replay bei Grenzzeit +299 s mit Löschjob dazwischen → weiter 409.
Bei DB-Ausfall 503. Geschäftlicher Retry verwendet frische Hülle/Nonce/requestId
und denselben Ingest-Idempotenzkey; neuer Hüllenhash ist kein geänderter
fachlicher Requestdigest. `Idempotency-Key` bleibt separater Ingestvertrag.
Transportklartext/Schlüssel nur im RAM; persistiert werden normale :2/hpke-
Objekte, Replaymetadaten und sichere Ergebnisse, niemals die entschlüsselte Hülle.

Abnahme: falsches Formular/Pfad/Keyversion, manipulierte AAD/Nonce/Tag/Signatur,
Replay über zwei Replikas, Rotation/Widerruf, Crash zwischen Reservierung und
Annahme, Uploadlimits vor/nach Base64-Dekodierung und Retry mit gleicher
fachlicher Identität. Hier keine Kryptovektoren oder Laufzeitprüfung ausgeführt.

## Vertragsrunde 3 — R05: formularbezogene Einstellung (VORGESCHLAGEN)

Stand 28.10.2026. Bedeutung, Speicher und Durchsetzung der Wahl aus ADR 0003
Nr. 4 / ADR 0004 Nr. 2. Die **Produktwahl zwischen `offered` und `required`**
(und ob `offered` überhaupt gewünscht ist) ist nicht entschieden; siehe
`docs/handoffs/vertragsrunde-3-offen.md`. Der technische Vertrag unterstützt
alle drei Werte, Standard `off`.

| `security.transport` | Reguläre Routen (`/api/v2/…`, Aliase) | Transportrouten | Legacyadapter |
| --- | --- | --- | --- |
| `off` (Standard) | zugelassen | 403 einheitlich (kein Hinweis) | wie bisher möglich |
| `offered` | zugelassen | zugelassen | möglich |
| `required` | 403 `transport-required` ohne Nebenwirkung | zugelassen | **nicht aktivierbar**; bestehende Bindung wird abgelehnt |

- **Speicher/DTO:** Feld `security.transport` der versionierten Formulardefinition
  (`../flow/form.schema.json`), Spalte `form_versions.transport_policy`
  (`../data/schema-entwurf.sql`), Antwort der Formularkonfiguration optional
  `configuration.transportPolicy` und `transportKeyVersion`
  (`../ingest/ingest.openapi.yaml`). Die Wahl ist Teil der Releasebestätigung;
  nur `release.publish` mit menschlicher Bestätigung ändert sie (keine eigene
  heimliche Routensperre, keine Änderung außerhalb eines Release).
- **Voraussetzung (Vertragsrunde 4, T4):** Veröffentlichung mit `offered|required` nur,
  wenn **beide** `form_protocol_keys(purpose='transport', state='current')` und
  `form_protocol_keys(purpose='ed25519', state='current')` existieren, sonst 409 an der
  Veröffentlichung. Die Hülle verlangt immer eine gültige Ed25519-Signatur und kennt
  keine Signaturausnahme; ohne aktuellen Ed25519-Schlüssel wären alle Hüllen 403 und
  `required` sperrte zugleich die reguläre Route. Fällt einer der beiden Schlüssel
  später aus (Widerruf/Ablauf), gilt bei `required`: Transportroute und reguläre Route antworten 503
  `transport-unavailable` (Ausfall beider Schlüssel ist Abnahmefall); **kein Downgrade** auf reguläre Routen, keine
  Ableitung der Politik aus dem bloßen Vorhandensein eines Schlüssels.
- **Schlüsselwechsel** ändert nur die Generation (current/previous mit Ablauf,
  Widerruf sofort), nie die Politik.
- **SDK:** `required` erwartet, dass das SDK die Formularkonfiguration ebenfalls
  über die Transportroute lädt (die Konfiguration dort enthält `transportPolicy`).
  Ein Alt-SDK ohne Transportfähigkeit erhält 403 und muss vor der Umstellung auf
  `required` aktualisiert sein; Abnahme: SDK-Matrix.
- **Provisionierung (OFFEN):** Der Provider und der administrative Kanal bleiben
  offen und blockieren die Aktivierung (bisher). Vorschlag für die
  Berechtigung: bestehendes Recht `key.manage` im Formularscope zum Anlegen/
  Rotieren/Widerrufen des Transportschlüssels (kein neues Recht erfunden); der
  Schlüssel erscheint genau einmal in der Antwort an den berechtigten Menschen
  über TLS (`Cache-Control: no-store`), wird serverseitig nur als `secret_ref`
  geführt und niemals im Paketexport/Log. Alternative: Betriebsprovider. Wahl offen.
- **Abnahme (nicht ausgeführt):** `off/offered/required` gegen reguläre Route,
  Transportroute, Adapter; Schlüsselausfall bei `required`; Release ohne Schlüssel;
  Politikwechsel nur über Release; Rollback des Release stellt die frühere
  Politik wieder her.

R06 (Digestabbildung): `../ingest/README.md`, Abschnitt Vertragsrunde 3 R06.

## Vertragsrunde 4 — Schlüssellebensdauer und Ressourcen (VORGESCHLAGEN, T6)

- **Nonce-Obergrenze:** 96-Bit-Zufallsnonce unter einem Dauerschlüssel: höchstens 2^32
  Hüllen je Schlüsselgeneration (NIST SP 800-38D), betrieblich Rotation spätestens bei
  2^30 (Zähler aus `transport_replays` je Generation); Überschreitung → Rotationspflicht,
  Meldung an `key.manage`. Zusätzlich Rotation bei unklarem Senderzustand.
- **Größenlimit vor Hashing:** Die Signatur verlangt SHA-256 über den gesamten
  `ciphertext`; daher gilt ein hartes Limit der Rohgröße des Request-Bodys **vor**
  Base64-Dekodierung und Hashing (Streaming-Abbruch, kein Puffern darüber). Wert =
  Summe der Formular-Upload-Limits × 4/3 + 4 KiB Hüllenaufschlag; konkrete Zahlen
  sind Teil von D11 (offen). Limits werden nicht erst in der Abnahme geprüft.
- **Nonce/Reservierungs-DoS:** Reservierung erst nach gültiger Signatur (unverändert).
