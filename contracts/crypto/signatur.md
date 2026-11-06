# Ed25519 und PHP-Kanonisierung

SPDX: AGPL-3.0-only. Maßgeblich ADR 0002; Belege `bvk:providers/AnfrageSignatur.php:34–245`, `Clients/BackendV2.php:267,348–390,711–749`, `SignaturschluesselProvisionierung.php`, `FormularSchluessel.php:285–348`; review-D S22–S24/F3. Ergänzt [P2-1](../ingest/README.md), ersetzt dessen ausdrücklich vorgeschlagene Regeln nicht durch Beschlüsse.

## Signaturtext

Detached Ed25519, Public Key 32 Rohbytes, Signatur 64 Rohbytes. SDK-Privatschlüssel im Altvertrag: libsodium-Secret-Key[64], nur auf dem Kundensystem. Kein Austausch mit X25519-Schlüsseln. Header `X-Kubus-Timestamp` und `X-Kubus-Signature` (Standard-Base64). Altleser dekodiert Signatur/Public Key mit strengem PHP-Base64-Decode, ohne kanonischen Rückkodierungsvergleich. Writer erzeugen kanonisches Standard-Base64.

Exakte UTF-8/ASCII-Bytes, LF=`0x0a`, kein abschließender LF:

```text
KUBUS-V2\n<METHOD>\n<PATH>/?f=<ENCODED_UUID>\n<TIMESTAMP>\n<BODY_HASH>
```

- METHOD = `strtoupper(methode)`; öffentliche betreffenden Routen verwenden `POST`.
- Pfadnormalisierung exakt PHP: `'/' . ltrim((string)(parse_url(pfad, PHP_URL_PATH) ?: pfad), '/')`; anschließend `rtrim(normalisierterPfad,'/')`. Für Submit `/api/v2/submit`, für Konfiguration `/api/v2/form`. Skriptalias ändert den vom Handler vorgegebenen Signaturpfad nicht.
- UUID unverändert mit PHP-`rawurlencode`: UTF-8-Bytes percent-kodieren, RFC-3986-unreserved `A–Z a–z 0–9 - . _ ~` bleiben stehen, Space wird `%20`, nicht `+`. Andere Queryparameter/Host/Origin/Idempotency-Key sind nicht im Text gebunden.
- TIMESTAMP ist die unveränderte dezimale Headerzeichenfolge; Altprüfung verlangt String, `^[0-9]+$` mit absolutem Ende, gültigen PHP-Integer (`FILTER_VALIDATE_INT`) und Zeitabstand höchstens 300 Sekunden. Keine Trim-/Neuformatierung beim Signieren. Überlauf oder vom Integerfilter abgelehnte Darstellung wird nicht als gültige Zeit übernommen. Sender verwenden gewöhnliche dezimale Unixsekunden. ±300 einschließlich zulässig; ±301 unzulässig. Plattformgrenzen/führende Nullen durch Vektoren prüfen, keine zusätzliche Toleranz erfinden.
- BODY_HASH ist lowercase Hex[64] von SHA-256 der folgenden JSON-Bytes.

## Kanonischer Inhalt

```php
json_encode(
    ['fields' => sortiereRekursiv($post), 'files' => dateien($files)],
    JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR
)
```

Diese PHP-Kodierung ist verbindlich, **keine** JCS/RFC-8785-Kanonisierung und kein Hash der Multipart-Rohbytes. Keine eingerückte Ausgabe; äußere Reihenfolge `fields`, dann `files`. Unicode und Slash mit genau diesen Flags behandeln; keine zusätzliche Unicode-Normalisierung, andere Escape- oder Floatregel. Standardverhalten für übrige Zeichen, z. B. Steuerzeichen und Unicode-Zeilentrenner, bleibt PHP-`json_encode`. Ungültiges UTF-8 ist ein Kodierungsfehler, kein Ersatzzeichen oder leeres Objekt.

`sortiereRekursiv`: Nichtarrays behalten skalaren Typ und Wert bzw. `null`; andere Werte werden im Altcode nach String gecastet. PHP-Listen (`array_is_list`, lückenlose Integerkeys ab 0) behalten Reihenfolge. Andere PHP-Arrays werden vor rekursiver Verarbeitung ihrer Werte mit `ksort(SORT_STRING)` sortiert. Leere PHP-Arrays bleiben `[]`; auch `fields` und `files` können `[]` sein. Ein assoziatives Array ist nicht automatisch eine Liste; numerische PHP-Schlüsselkonvertierung und lückenhafte Indizes sind Teil des Parser-/Fixturevertrags. Keine allgemeine UTF-16-Sortierung oder alphabetische Neusortierung der äußeren Hülle.

Submit-SDK hasht das ursprüngliche `$_POST`, bevor es für HTTP abflacht. Der Transporthelfer schreibt bool zu `1`/`0`, Zahlen zu Strings und verschachtelte Namen in Klammernotation. Für gewöhnliche HTTP-Stringfelder besteht der Kompatibilitätsweg; für programmatisch eingebrachte bool/int/float-Werte ist Gleichheit mit dem abgeflachten Wireinhalt **nicht** pauschal garantiert. Die Portierung muss die tatsächliche PHP-Struktur nachbilden. **OFFEN K13:** P2-1 muss unterstützte PHP-Formparser-Grenzfälle und kanonisierbare Eingabetypen anhand SDK-/Swift-Kreuzvektoren abnehmen; keine Änderung der signierten Bytes als Reparatur.

## Dateimetadaten

Dateifelder zuerst `ksort(SORT_STRING)`; Nichtarray-Einträge ignorieren. Je Datei:

1. Bei Array unter `name` über dessen Schlüssel in vorhandener Reihenfolge iterieren und rekursiv Teile bilden. Erfolgreiche Teile mit `resultat[]` als neue Liste sammeln; erfolglose Teile entfallen. Leere Dateifelder entfallen vollständig.
2. Bei Einzeldatei `error` nach int casten, Standard `UPLOAD_ERR_NO_FILE`; nur `UPLOAD_ERR_OK` (0) wird berücksichtigt.
3. Metadatenobjekt exakt in Reihenfolge `name`, `type`, `error`, `size`, `sha256`: Name und Typ nach String, fehlend `""`; error Integer 0; size nach int, fehlend 0; sha256 lowercase Hex von Rohdateibytes, falls `tmp_name` String und reguläre Datei, sonst JSON `null`. Temporärpfad selbst wird nie signiert.

Der Altfall `sha256=null` ist belegt und für Kanonisierungsfixtures zu erhalten. Er erlaubt keine fehlende Uploadvalidierung: Autorisierung, Dateigröße und Annahmeregeln sind unabhängig zusätzlich zu prüfen. Erfolglos hochgeladene Dateien werden durch Weglassen im Hash nicht zu erfolgreich angenommenen Dateien.

## Pflicht, Provisionierung, Rotation und Fehler

Submit und Formkonfiguration verlangen registrierten Public Key und gültige Signatur. Fehlend/ungültig/außerhalb Zeitfenster → 403 gemäß P2-1; kein bisheriger pauschaler Bypass bei leerem Schlüssel. Eine Ausnahme nach ADR 0002 ist je Formular zeitlich begrenzt, protokolliert, widerrufbar. **OFFEN K14:** Dauer, Vergabe-/Widerrufsrechte und genaue Detailsemantik der Ausnahme bestätigen; P2-1 schlägt sieben Tage vor, das ist kein Beschluss. Keine voreingestellte unbefristete Ausnahme.

Provisionierung und Schlüsselrotation bleiben beim separaten Key-Vertrag aus P2-1: kanonisches Base64 des neuen Public Keys, keine privaten Schlüssel, erste Registrierung nur mit verifizierten formularbezogenen UA-/IP-Signalen und Provisionierungs-HMAC. Die dazugehörigen Texte, jeweils ohne abschließenden LF, sind:

```text
KUBUS-V2-KEY-PROVISIONING\nPOST\n/api/v2/key/\n<uuid>\n<ts>\n<newPublicKeyBase64>
KUBUS-V2-KEY-ROTATION\n<uuid>\n<ts>\n<newPublicKeyBase64>
```

Ersttext: HMAC-SHA256, Schlüssel=`UA_raw[32]||IP_raw[32]`; gültige aktuelle/vorherige Kombinationen, Zeitfenster ±300 s. Rotationstext: detached Ed25519 mit bisherigem Schlüssel, ebenfalls ±300 s. Atomarer bedingter Ersatz des aktuellen Public Keys; alter aktueller wird vorheriger für sieben Tage. Ein zweiter Ed25519-Wechsel verdrängt den älteren Vorgänger sofort; die zusätzliche Header-Rotationssperre gilt hier im Altcode nicht. Wiederholungs-/Statusdetails gemäß P2-1, insbesondere kein erfundener immer signaturpflichtiger Bootstrap. K12 in migration.md bleibt eine Grenze für globale Alt-Schlüssel.

Prüfung von aktuellem und noch gültigem vorherigem Signaturkey; bei Gültigkeitsgrenze entspricht das Altverhalten `gueltigBis >= now`. Reset darf nicht automatisch einen unbefristeten Signaturbypass eröffnen. Provisionierung und Ausnahmen werden ohne Geheimnisse auditiert.

Kanonisierungs-Exceptions sind von regulärem Signatur-`false` zu unterscheiden. Alt-Signaturpfad fängt `JsonException` lokal nicht ab; ein konkreter HTTP-500-Ausgang ist statisch nicht nachgewiesen. Späterer Idempotenzpfad fängt diese Exception und antwortet 412 (`AnfrageIngest.php:159–170`). Neue Zuordnung für nicht kodierbare Eingaben bleibt OFFEN K05; zwingend sind Ablehnung ohne Verarbeitung/Nebenwirkung und kein Ausweichen auf ungeprüfte Annahme. Ein Zeitfenster verhindert keinen Replay innerhalb des Fensters; Idempotenz ist ein separater Ingest-Vertrag.


Technischer Nachtrag M02 (VORGESCHLAGEN): Signaturprüfung erfolgt über die
unveränderte kanonische POST-/Dateidarstellung einschließlich technischer
CSRF-/Botfelder. Erst danach technische Prüfung und Abtrennung der vier
reservierten Technikfelder gemäß `../ingest/README.md`, dann fachliche
Normalisierung und Persistenz. Technikwerte gelangen in keine Nutzpakete oder
Logs. Bestehende Signatur-/bodyHash-Kanonisierung wird nicht geändert.

## Vertragsrunde 3 — R03: getrennte Signierer (VORGESCHLAGEN)

Der native SDK-Schlüssel (`form_protocol_keys`, purpose `ed25519`, ein
`current` plus ein befristeter Vorgänger wie oben) ist der **einzige** Satz, den der
öffentliche Pfad prüft. Der Adapter (`../ingest/legacy-adapter.md`) hat ein
eigenes Register `adapter_signers` mit eigener Generation, Rotation und eigenem
Widerruf und signiert einen eigenen Text (`KUBUS-ADAPTER-SIGN-1`); er wird nur
auf dem mTLS-authentisierten Dienstlistener akzeptiert. Es gibt keinen Fallback
und kein Probieren des jeweils anderen Satzes; der zweite Wechsel des einen Satzes
verdrängt den Vorgänger des anderen nicht. Die Eingangs- und Idempotenzaufzeichnung
bindet Signiererart, Generation und ggf. Adapterbindung (`../data/abbildung.md`).
Ausnahme nach ADR 0002 (`signature_exceptions`) gilt nur für den nativen Pfad und
nie für den Adapter. Die 7-Tage-Vorgängerfrist und die Adapterlaufzeit sind
unbestätigte Vorschlagswerte.

## Vertragsrunde 4 — Kanon und Strenge (VORGESCHLAGEN, Review A4/A7)

Stand 30.10.2026, Bezug `docs/paritaet/review-krypto-adapter.md`. Nichts ausgeführt.
Die Bytes des nativen Texts (`KUBUS-V2`) bleiben unverändert; die Regeln gelten für
die neuen Texte (`KUBUS-ADAPTER-SIGN-1`, `KUBUS-TRANSPORT-SIGN-1`/AAD) und stellen
die native Form nur klar.

**Pfadliterale (eine Quelle, aus Routenkonstanten, nie aus Rohpfad oder Rohquery):**

| Text | Zeile `<path>` im Text | Wire-Pfad |
| --- | --- | --- |
| nativ `KUBUS-V2` (unverändert) | `/api/v2/submit/?f=<uuid>` bzw. `/api/v2/form/?f=<uuid>` | `/api/v2/submit/`, `/api/v2/form/` |
| Adapter `KUBUS-ADAPTER-SIGN-1` | `/api/v2/submit/?f=<uuid>` bzw. `/api/v2/form/?f=<uuid>` | Dienstlistener, gleiche Pfade |
| Transport `KUBUS-TRANSPORT-1`/`-SIGN-1` | `/api/transport/v1/submit?f=<uuid>` bzw. `/api/transport/v1/form?f=<uuid>` (ohne Slash) | `/api/transport/v1/submit/`, `/api/transport/v1/form/` |

Die Unterscheidung (Slash im nativen/Adaptertext, keiner im Transporttext) ist
Absicht: der native Text ist Altbytevertrag, der Transporttext ist neu. Ein Pfad,
der nicht genau einer dieser Routenkonstanten entspricht, erreicht die
Signaturprüfung nicht. Pro Route genau ein Wert; nie zwei Pfadvarianten akzeptieren.

**Wertkanon der neuen Texte:**

- UUIDs (formId, Bindung, requestId): Kleinbuchstaben-Hex in 8-4-4-4-12, sonst
  abgelehnt (keine Normalisierung). Die Query `f` muss denselben Wert tragen; sie wird
  nicht aus der Rohquery in den Text übernommen, sondern der Text aus dem geparsten
  `f` gebildet, nachdem es gleich `formId` bzw. dem Pfadparameter ist.
- `timestamp`: Headerstring roh signiert, kanonisch `^[1-9][0-9]{0,11}$` (kein führendes
  `0`, kein `0`, kein Vorzeichen, kein Leerzeichen); Abweichung → 403, bei Transport
  zusätzlich Gleichheit mit dem Hüllenfeld. ±300 s einschließlich.
- Ganzzahlen (`keyVersion`): JSON-Integer `^[1-9][0-9]{0,18}$` bis 2^63−1, ohne Exponent,
  Bruchteil, führende Null; die Textdarstellung ist die Dezimalform.
- Abwesender optionaler Wert (Idempotency-Key, Attested-IP, Attested-Origin) ist eine
  **leere Zeile**; optionale Zeilen stehen nie als letzte Zeile (die letzte Zeile ist
  immer ein Pflichtwert), damit „kein abschließender LF“ eindeutig bleibt.
- Effektiver `Idempotency-Key` in neuen Texten: Wert nach PHP-`trim`, 1–190 Byte,
  sonst abwesend (wie `../ingest/README.md`). Ein Key mit LF/NUL ist ungültig und
  zählt als abwesend; ein anderer Rohwert desselben Headers kann also nie zu einem
  anderen Textinhalt führen als beim Signierer.

**Ed25519-Strenge (alle Texte, A7).** Verifizierer (Kern, PHP/libsodium, Swift/CryptoKit,
Browser) müssen: Signaturlänge exakt 64, Public Key 32 Byte; `S < L` (kein
nicht-kanonisches S), Ablehnung von Public Keys und `R` kleiner Ordnung sowie
nicht-kanonischen Punktkodierungen; kein Fallback auf lockere Verifikation. Ein Kern,
dessen Bibliothek das nicht garantiert, gilt als nicht abnahmefähig. Replay- oder
Idempotenzschlüssel werden **nie** aus Signaturbytes gebildet (Malleabilität); die
Replayregister verwenden den Hash des signierten Texts bzw. Nonce/requestId.
Pflichtvektoren (nicht berechnet): `S = L`, `S = L + s`, Public Key kleiner Ordnung,
nicht-kanonisches `R`, 63/65-Byte-Signatur, kanonisch gültige Signatur als Positivfall,
jeweils PHP, Swift und Kern gleich; siehe `test-vectors.md`.

**Registereindeutigkeit (A5):** Kein öffentlicher Ed25519-Schlüssel darf in
`form_protocol_keys(purpose='ed25519')` und `adapter_signers` zugleich vorkommen;
Adapterschlüssel sind global eindeutig und umgebungsgebunden (Details
`../ingest/legacy-adapter.md`).

**Veröffentlichungsvoraussetzung:** siehe `transport.md` (T4); gilt für `offered|required`.

## SDK-Failover (P7-F)

Der Submit-Signaturtext ist hostunabhängig. Zusätzliche aktive, formularbezogen zugelassene API-Hosts akzeptieren dieselbe signierte Anfrage und denselben Idempotenzschlüssel. Signierte SDK-Endpunktliste, Vertrauensanker und Fehler-/Budgetsemantik: [ADR 0020](../../docs/decisions/0023-sdk-failover.md). Keine Änderung der kanonischen Submit-Bytes.
