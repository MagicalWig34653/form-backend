# Testvektorplan P2-2

SPDX: AGPL-3.0-only. **Plan, nicht ausgeführt.** Keine Tests, Builds oder Skripte des Altprojekts wurden für P2-2 ausgeführt. Alle späteren Vektoren verwenden ausschließlich neu erzeugte synthetische Schlüssel, Passphrasen, Credential-IDs und Nutzdaten. Keine Schlüsselwerte aus Altcode, Konfiguration, DB, Browserprofil oder `secrets/` kopieren. Synthetische private Fixture-Schlüssel sind ausdrücklich als öffentliches Testmaterial zu kennzeichnen und niemals produktiv zu verwenden.

## Erzeugungsverfahren nach gesonderter Freigabe

1. Separate isolierte Fixture-Werkstatt außerhalb des Altprojekts anlegen. Nur geprüfte notwendige Altquellen lesend übernehmen, Lizenzhinweise erhalten, Snapshot/Dateihashes und verwendete Funktionen protokollieren. Keine Secretdateien oder impliziten Konfigurations-/DB-Bootstraps übernehmen. Die aktuellen Lese-/Nichtausführen-Grenzen bleiben bis zu einem neuen Auftrag bestehen.
2. Abhängigkeiten statisch auf Seiteneffekte prüfen. Reine Kryptomodule in der Kopie verwenden; für Datenbank-/Login-abhängige Leser nur die genau belegten reinen Funktionen in einen dokumentierten Testadapter extrahieren. Nie Originalskripte laden, die produktive Konfiguration lesen könnten. Kein altes Compose-/Kompat-Skript ungeprüft starten: es erzeugt Dateien und führt DB-/Testbefehle aus.
3. Tatsächliche PHP-, OpenSSL-, Sodium-, Node-/Browser- und spätere Swift-/Bibliotheksversionen erfassen und reproduzierbar fixieren. Kein `latest` als reproduzierbaren Nachweis ausgeben. Kryptozufall ausschließlich im Harness für Festvektoren kontrolliert ersetzen; produktive Quellen bleiben unverändert.
4. Bei `PaketV2::verschluessele` die vorgesehenen Testparameter CEK, IV, skE verwenden. Für zufällige Wraps entweder in der isolierten Kopie einen dokumentierten Zufallsprovider injizieren oder einmal erzeugte synthetische Bytes samt Ergebnis fixieren. Produktionsinterfaces nicht um deterministische Nonces erweitern. RSA-Schlüssel in der Werkstatt erzeugen; der alte Erzeugungsaufruf aus `scripts/kompat-test.sh:254–258` ist eine Quelle, kein hier auszuführender Befehl.
5. JSON-Manifest je Fall: ID/Zweck, Quellfunktion/Zeilen und Snapshot, Runtimeversionen, Typinformation der Eingabe (PHP-Liste/assoziatives Array/Skalartyp), Eingangsbytes, erwartete Zwischen-/Ausgangsbytes und Fehlerklasse. Binärwerte eindeutig als Hex oder benanntes Base64, niemals verlustbehaftet als Text. Signaturtext und kanonische JSON-Bytes zusätzlich in Hex; Testzeit explizit fixieren. Kein gewöhnlicher Debugdump.
6. Ergebnisse zunächst aus Alt-PHP bzw. Alt-JS gewinnen, dann unabhängig mit neuer Swift-/Browser-/PHP-Implementierung prüfen. Erwartungswerte nicht mit der zu prüfenden Neuimplementierung berechnen. Bei Differenzen weder Erwartungen still ändern noch Defaults raten: Ursache, Version und Entscheidung dokumentieren. Manifest mit Prüfsumme und Erzeugungsanleitung ablegen; erst nach Review als Referenz freigeben.

## Öffentlicher HPKE-Vektor

Lokaler belegter Verweis: `bvk:tests/fixtures/hpke-rfc9180-base-x25519-sha256-aes256gcm.json`; zugehörig `HpkeTest.php`, `krypto-hpke.mjs`, `KryptoKreuzTest.php`. Das `_quelle`-Feld verweist auf die [öffentlichen CFRG/RFC-9180-Testvektoren, festgelegter Commit](https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hpke/5f503c564da00b0687b3de75f1dfbdfc4079ad31/test-vectors.json), SHA-256 der dort bezeichneten Originaldatei `61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6`, Filter mode 0, kem `0x0020`, kdf `0x0001`, aead `0x0002`. Hier wurde nur die lokale Herkunftsangabe gelesen; Remoteinhalt und Hash sind nicht neu verifiziert. Keine öffentlichen Schlüsselbytes abgeschrieben.

Die gefilterte Suite ist entscheidend; keine aus D übernommene ungeprüfte Anhangsnummer als Beleg. Vor Verwendung Originalhash und Suite prüfen. KEM/shared_secret, key_schedule_context, key, base_nonce und Sequenz-0-Chiffrat gegen unabhängige Bibliothek prüfen. Der RFC-Datensatz enthält weitere Sequenzfälle und Exporte; sie dienen Bibliotheksprüfung, erweitern aber nicht den Paketvertrag „ein Seal, Sequenz 0“. Negative Null-DH-/Schlüssellängenfälle ergänzen.

## Verbindlicher Fallkatalog

| Gruppe / Altquelle | Zu erzeugende Vektoren und Abnahme |
| --- | --- |
| :2/hpke – `PaketV2Test.php`, `KryptoKreuzTest.php`, `krypto-paket-v2.mjs` | Synthetisches sk_D/skE, CEK und IV fixieren; `pk_D`, Digest/`kid`, enc, gewickelter CEK, Nutz-ct/tag und kompletter Paketstring bytegleich PHP→JS→Swift. Klartexte leer, UTF-8, NUL/Binärdaten. |
| :2/sym – `PaketV2Test.php`, `krypto-umhaengen.mjs` | KEK_L-Zwischenwert mit leerem Salt prüfen; Wrap-IV fixieren; CEK-Wrap und Nutzdaten separat prüfen. Authentifizierter leerer Klartext bleibt Erfolg. |
| Parser – `PaketV2Test.php` und Browserparser | Segmentzahl, falsches Präfix/Wrap, Großbuchstaben-`kid`, abschließender LF, Base64url, Whitespace, Padding/Pad-Bits, leere Pflichtsegmente und jede falsche Rohbyte-Länge ablehnen; leeres `ct` akzeptieren. |
| Authentifizierung – HPKE/GCM-Tests | Je ein Bit in enc/Wrap-IV/Wrap-ct/Wrap-Tag/Nutz-IV/ct/tag ändern; falsches `kid`, Schlüssel, info und AAD; keine Klartextausgabe. Strukturell gültiger manipulierter Wrap darf nicht als kryptografisch geprüft gelten. |
| Kontomodell – `krypto-schluessel-modell.mjs`, `krypto-prf-ablage.mjs` | Synthetische PRF-Ausgabe[32], Credential-ID an Längengrenzen und sk_K; KEK_P, Wrap, Öffnen; HKDF-Credential-Salt gegen PRF-Salt-Verwechslung; mehrere Credentials für dasselbe Paar; Datenzugang auf pk_K und falsches `kid` nach Öffnen; skDVerpackt mit exakter Ablage-AAD. |
| PRF-Zeremonie – `prf.js`, `KryptoBrowserRegelnTest.php` | Fake-Credential für Parser-/Optionenfälle (keine echte Authenticator-Ausgabe vortäuschen); fehlende/falsche PRF-Länge, anderes Credential, Abbruch, fehlende Fähigkeit. Separat echte Browser-/Authenticatorprüfung bei unveränderter RP-ID; Fixture-PRF beweist keine Gerätesupport-Aussage. |
| Recovery – `krypto-schluessel-modell.mjs`, UI-Normalisierung | Derselbe synthetische Code groß/klein, mit/ohne Bindestriche, Space/Tab/LF und ECMAScript-Unicode-Whitespace muss identische normalisierte UTF-8-/KEK_R-Bytes liefern. 23/24 UTF-16-Einheiten nach Normalisierung; Unicode-Großschreibung, keine NFC/NFKC. Fixe Salt/IV, genau 600000 Iterationen; falsche Passphrase/Parameter/`kid` müssen scheitern. Generatorformat 8×4 aus belegtem Alphabet prüfen. |
| Umhängen – `UmhaengenTest.php`, `krypto-umhaengen.mjs`, `krypto-rotation.mjs` | hpke→sym gleiches kid; Generationswechsel hpke→hpke und sym→sym sowie erlaubtes hpke→sym. Nutz-IV/ct/tag unverändert; sym→hpke, falsches Ziel/kundenfremdes kid, veränderte Nutzbytes, fehlendes Anhaltepaket ablehnen. Server kann falschen CEK bei gültiger Struktur nicht erkennen; Browser muss nach Umhängen denselben Klartext öffnen. |
| Generation/Entzug – `SchluesselverwaltungTest.php`, `ZweiGenerationenTest.php` | Echte Transaktions-/Raceprüfungen in neuer synthetischer DB: zwei Einrichtungen/Rotationen, fehlende/mehrere aktive, auslaufende vorhanden, entzogene Zugänge nicht wiederhergestellt, letzter Admin geschützt, Sperren gegen Entzug. Eingang nach Rotation nur neu; Abschluss blockiert durch jede der vier Altspalten und neue externe Referenzen. Abbruch/Retry kein Teilzustand. |
| :1/CBC – `CryptoTest.php`, `ChiffrateTest.php`, `AnfrageverschluesselungTest.php` | Synthetisches RSA-Paar und Passphrase; :1-CEK/IV/AAD/tag und CBC-IV/Padding fixieren bzw. vollständige einmal erzeugte OAEP-Fixture einfrieren. OAEP ist randomisiert: Roundtrip allein ist kein bytegleicher Erzeugungsvektor. K02/K03 separat bestimmen; falsche Passphrase, unbekannte Version, Base64-/IV-/Tagfehler und Paddingfehler. CBC fehlende Authentizität ausweisen. |
| MFA – `Crypto.php:129–149`, `login.php:320–374` | Synthetischer Schlüssel[32], IV[16], Secret: beide Base64-Zwischenstufen und Gesamtstring fixieren; einmal statt zweimal Base64 darf nicht unbemerkt passen. Klartextvorgänger separat; falsches Präfixformat, IV, Konfigurationsschlüssellänge, Padding/Leertext. Zielvertrag K11 vor Migration abnehmen. |
| v1-Signale – `RateLimiterKeyRotationTest.php`, `RateLimiterTest.php`, `SchluesselMigrationsstandTest.php` | Ausschließlich synthetische Rohstrings, auch 61 ASCII-Byte. K01: gleicher 32-Byte-Präfix, andere Suffixe, kurze/32/überlange Schlüssel; AES und HMAC getrennt vergleichen. IV/ct/MAC, nicht-strenges Base64, LF/trim/leere Signale, falscher MAC, Schlüsselreihenfolge und gemischte Treffer prüfen. IV-Manipulation demonstriert fehlende MAC-Bindung; nicht als vollständigen Integritätsschutz bezeichnen. |
| Signatur – `AnfrageSignaturTest.php`, `BackendV2SdkTest.php`, `AnfrageSubmitV2Test.php` | Synthetischer Ed25519-Seed/Keypair, feste Zeit; Original-PHP-Struktur, kanonische JSON-Bytes, bodyHash, Text, Signature fixieren. Umlaute/Slash/Steuerzeichen/U+2028/U+2029, verschachtelte Maps, Listen, leere Arrays, numerische Keys/lückenhafte Indizes, bool/int/float/null, Parser-/Transport-Unterschiede. Keine unabhängige Zahlendarstellung erraten. |
| Dateien/Signatur | Einzel-/Mehrfachdateien synthetisch, Binärdaten, Feldsortierung, Reihenfolge und ausgelassene error≠0-Teile; fehlende reguläre Datei → hash null; size Integer. Ungültiges UTF-8: Kodierungsfehler statt stiller Ersatz. Pfad mit/ohne Slash/Query, rawurlencode, unveränderter Timestamp, ±300/301, Integergrenzen, führende Nullen. |
| Provisionierung – `SignaturschluesselProvisionierungTest.php` | Fixe UA/IP[32], neuer Public Key und Timestamp; Provisionierungstext/HMAC sowie Rotationstext/Ed25519; gültiger Vorgänger, Ablaufgrenze, Wiederholung, konkurrierender Ersatz, zweiter Wechsel. Ohne gültige Signatur und ohne bestätigte Ausnahme ablehnen; Schlüsselreset öffnet keinen automatischen Bypass. |
| Import – `UmstiegTest.php`, `UmstiegSkriptTest.php` | Nur neue isolierte Werkstatt: alle vier Spalten, gemischte :1/CBC/:2, Base64-Mailklartext unverändert, Wiederanlauf nach Fehler, konkurrierende Rotation ausgeschlossen, Audit/Ausnahmen sichtbar. Neuer Laufzeitkern weist Altformate zurück. Kein Klartext in DB/Logs/Fehlerbericht. |

## Abschlusskriterien

Jeder freigegebene Vektor muss exakte erwartete Bytes oder eine bestimmte Fehlerklasse enthalten, nicht nur „Roundtrip funktioniert“. Cross-Language-Prüfungen müssen beide Richtungen abdecken, soweit die jeweilige Rolle schreibt/öffnet; serverseitiger Datenzugang wird dadurch nicht eingeführt. Keymanagement/Migration erfordern zusätzlich echte Integrations- und Wiederholungsprüfungen. Abweichungen und K01–K14 bleiben bis zum belegten Abschluss sichtbar. Unabhängiges Review vor Portierungs-/Cutover-Freigabe; keine Behauptung erfolgreicher Tests aus diesem Plan.

## Vertragsrunde 4 — zusätzliche Pflichtvektoren (VORGESCHLAGEN, nicht erzeugt)

Zu erzeugen nach Freigabe, jeweils exakte Bytes oder Fehlerklasse:

- Adapter-Signaturtext: Positivfall mit/ohne Idempotency-Key, mit/ohne Attested-IP/-Origin
  (leere Zeilen); Anfrage mit anderem/entferntem Key → 403; identische Anfrage zweimal →
  erste Annahme, zweite 409 `adapter_replays`; Replay bei Grenzzeit +299 s mit Löschjob dazwischen.
- Transport: AAD/Signaturtext mit Idempotency-Zeile, Header verändert → 403; `keyVersion`
  `1.0`, `1e0`, `01`, `0`, > 2^63−1 abgelehnt; `timestamp` `0`, `01`, 13 Stellen abgelehnt;
  Großbuchstaben-UUID abgelehnt; Pfadform (kein Slash im Transporttext) mit Fehlvariante.
- Ed25519 strikt: `S = L`, `S = L + s`, kleiner-Ordnung-Public-Key, nicht-kanonisches `R`,
  63/65 Byte, Positivfall; PHP, Swift und Kern identisch.
- Veröffentlichung `offered|required`: ohne Transport-, ohne Ed25519-Schlüssel, ohne beide.
- Digestabbildung D1–D4 und Manifest M1–M3: siehe `../ingest/README.md` Runde 4 (i)–(l) und
  `../data/objektinventar.md`.

## Rotation (ADR 0016)

Fester synthetischer Browser-Vektorsatz: `pwa/src/lib/crypto/fixtures/rotation.json`.
Er enthält ausschließlich Testschlüssel (Hex), Quellpakete, erwartete Klartextbytes
und im Browser erzeugte Ersatzpakete für hpke→hpke, hpke→sym und sym→sym.
Vitest öffnet die Ersatzpakete und prüft identische Nutzchiffratbytes;
`backend/Tests/FormCryptoTests/RotationInteropTests.swift` öffnet dieselben
Bytes mit Swift und prüft außerdem Ablehnung des alten Schlüssels.
Der Lauf ist separat im Handoff P-Rotation dokumentiert; das Vorhandensein
der Fixture ist kein Nachweis einer ausgeführten Swift-Prüfung.
