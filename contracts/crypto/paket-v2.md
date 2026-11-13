# Paket `KUBUS-AEAD:2`

SPDX: AGPL-3.0-only. Normative Grundlage: ADR 0001/0003; Bytebelege `bvk:providers/PaketV2.php:18–173`, `providers/Hpke.php:17–173`, `www/src/krypto/paket-v2.js`, review-D S1–S15. Notation: `||` verkettet Bytes; `ASCII(s)` hat weder BOM noch NUL-Terminator; Längen sind Byte. `b64` ist Standard-Base64 (`A–Z a–z 0–9 + /`, erforderliches `=`-Padding), kein Base64url.

## Wireformat und Parser

```text
KUBUS-AEAD:2|<kid>|<wrap>|<b64(A)>:<b64(B)>|<b64(iv)>|<b64(ct)>|<b64(tag)>
```

Genau sieben durch ASCII `|` getrennte Segmente, kein abschließender Zeilenumbruch, keine Leerzeichen, keine Vorverarbeitung durch `trim`. Präfix und Wrap-Art sind groß-/kleinschreibungsabhängig. Das vierte Segment enthält genau einen ASCII-Doppelpunkt.

| Feld | Verbindliche Bedingung |
| --- | --- |
| Präfix | exakt `KUBUS-AEAD:2` |
| `kid` | exakt 16 Zeichen aus `[0-9a-f]` |
| `wrap` | exakt `hpke` oder `sym` |
| `A` | bei `hpke`: `enc`, 32 Rohbytes; bei `sym`: Wrap-IV, 12 Rohbytes |
| `B` | 48 Rohbytes: verschlüsselter CEK (32) `||` Wrap-Tag (16) |
| `iv` | Nutzdaten-IV, 12 Rohbytes |
| `ct` | Nutzdatenchiffrat beliebiger Länge, auch null Byte |
| `tag` | Nutzdaten-Tag, 16 Rohbytes |

Jedes Base64-Segment MUSS streng dekodierbar sein und `b64(decode(s)) == s` erfüllen. Damit sind Whitespace, fehlendes/zusätzliches Padding, fremdes Alphabet und nichtkanonische Pad-Bits ausgeschlossen. Nur `ct` darf der leere String sein; alle anderen Base64-Werte sind nichtleer und erfüllen obige Rohbyte-Längen. Das erneute Serialisieren eines gültigen Pakets liefert dieselben ASCII-Bytes.

`kid = lowercase_hex(SHA256(pk_D_raw))[0:16]`: SHA-256 über exakt 32 öffentliche X25519-Rohbytes, nicht über Hex, Base64, PEM oder DER. Die 16 Zeichen repräsentieren die ersten acht Digestbytes. Der Server berechnet `kid` bei Generationsanlage selbst und prüft es gegen den gespeicherten Public Key. `kid` ist keine globale Mandantenidentität; jede Auflösung braucht den Kundenkontext. **OFFEN K06:** Behandlung von `kid`-Kollisionen und Überführung identischer Alt-`kid` in verschiedene Kunden mit P2-3 festlegen; niemals still einen abweichenden Public Key ersetzen.

## Nutzdaten und Umhüllungen

Je neuer Verschlüsselung: CEK = 32 kryptografisch zufällige Bytes, Nutzdaten-IV = 12 frische Zufallsbytes. AES-256-GCM verschlüsselt die unveränderten Klartextbytes mit CEK, AAD = `ASCII("KUBUS-AEAD:2")`, Taglänge 128 Bit. `ct` und `tag` werden getrennt serialisiert. Die Nutzdaten-AAD enthält bewusst weder `kid` noch Wrap-Art, damit ausschließlich der CEK umgehängt werden kann. Klartextkodierung (JSON, Datei, Mailtext) ist eine getrennte Inhaltsschicht; der Kryptovertrag interpretiert sie nicht.

| Wrap | Erzeugung |
| --- | --- |
| `hpke` | HPKE-Base `Seal(pk_D, info=ASCII("kubus-anfrage v2"), aad=ASCII(kid), pt=CEK)`. `A=enc`, `B=HPKE-ct||tag`. |
| `sym` | `KEK_L = HKDF-SHA256(IKM=sk_D_raw[32], salt=leere Bytefolge, info=ASCII("kubus-langzeit v1"), L=32)`. AES-256-GCM mit KEK_L, frischem Wrap-IV[12], AAD=`ASCII(kid)`, Klartext=CEK, Tag[16]. `A=Wrap-IV`, `B=ct||tag`. |

Bei leerem HKDF-Salz gilt die HKDF-Leersalzsemantik (Nullbytes der Hashlänge); kein Text `""`, kein `kid` als Salz. Beim Öffnen MUSS der Schlüsselbund zum `kid` passen und der entpackte CEK exakt 32 Byte haben. Danach authentifiziert GCM die Nutzdaten. Alle Authentifizierungsfehler brechen ab. CEK und vorübergehende Rohschlüssel sind nach Verwendung soweit technisch möglich zu überschreiben. Produktion verwendet keine deterministischen CEK/IV/skE-Testparameter.

Der Server besitzt zum Speichern nur `pk_D` und erzeugt `hpke`. `sym` erfordert KEK_L/sk_D und wird durch den berechtigten Browser erzeugt, insbesondere beim Anhalten/Umhängen. `PaketV2::entschluessele` im Altprojekt ist ausdrücklich ein Testhelfer und kein serverseitiger Datenzugang. Initiale Klartextverarbeitung im Speicher für Mail ist davon getrennt erlaubt.

## Feste HPKE-Suite

RFC-9180-Base-Modus `0x00`, keine PSK, kein authentisierender Senderschlüssel:

| Parameter | Wert |
| --- | --- |
| KEM | DHKEM(X25519, HKDF-SHA256), `0x0020` |
| KDF | HKDF-SHA256, `0x0001` |
| AEAD | AES-256-GCM, `0x0002` |
| Rohschlüssel / `enc` | je 32 Byte |
| AEAD-Key / Nonce / Tag | 32 / 12 / 16 Byte |
| Kontextnutzung | ein Seal je frischem Kontext, Sequenznummer 0; Nonce = base_nonce |

IDs werden als zwei Byte big-endian kodiert. KEM-Suite-ID=`ASCII("KEM")||I2OSP(0x0020,2)`; HPKE-Suite-ID=`ASCII("HPKE")||I2OSP(0x0020,2)||I2OSP(0x0001,2)||I2OSP(0x0002,2)`.

Mit RFC-LabeledExtract/-Expand (Präfix `ASCII("HPKE-v1")`, Länge beim Expand zwei Byte big-endian):

```text
enc = X25519_public(skE)
dh = X25519(skE, pkR)
kem_context = enc || pkR
eae_prk = LabeledExtract_KEM(empty, "eae_prk", dh)
shared_secret = LabeledExpand_KEM(eae_prk, "shared_secret", kem_context, 32)
context = 0x00 || LabeledExtract_HPKE(empty, "psk_id_hash", empty)
               || LabeledExtract_HPKE(empty, "info_hash", info)
secret = LabeledExtract_HPKE(shared_secret, "secret", empty)
key = LabeledExpand_HPKE(secret, "key", context, 32)
base_nonce = LabeledExpand_HPKE(secret, "base_nonce", context, 12)
```

Empfänger rekonstruiert `pkR` aus `skR` und nutzt `X25519(skR, enc)`. Ungültige Schlüssel, fehlgeschlagenes DH und ausschließlich nullwertiges DH-Ergebnis werden abgelehnt. Keine Suite-Aushandlung oder Ersatzsuite. HPKE authentifiziert hier den Inhalt gegenüber dem Empfänger, nicht den Absender; Ed25519 ist ein separater Vertrag.

Die 32 Rohbytes sind das Austauschformat. PHP-interne X25519-SPKI-/PKCS#8-Hüllen sind Bibliotheksadapter (`Hpke.php:25–26`); sie bestimmen keine RSA-PEM-Altformate. Implementierung mit bewährten Bibliotheken und unabhängigen RFC-/Kreuztests, nicht bloß Übernahme eigener Altprimitiven.


## Abgrenzung nach ADR 0004

`hpke`/`sym` hier bezeichnet ausschließlich den CEK-Wrap eines gespeicherten
Pakets. Neue Formularspeicherung ist hpke-v2; das auswählbare Speicherprofil
sym-v2 bleibt gesperrt. Die zusätzliche symmetrische Transporthülle ist ein
eigener Vertrag in [transport.md](transport.md). Bestehende sym-Pakete und
zulässiger Nachschutz werden dadurch nicht umgedeutet.
