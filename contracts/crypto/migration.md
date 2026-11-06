# Altleseverfahren – ausschließlich Migrationswerkzeug

SPDX: AGPL-3.0-only. ADR 0001 ist maßgeblich; ältere „Neubau muss lesen“-Aussagen in D erlauben keine Altdecoder im Laufzeitkern. Quellen: `bvk:providers/Crypto.php:65–149`, `login.php:320–374`, `Ratelimiter.php:53–117,300–334,408–434,740–765`, `Clients/Backend.php:44–50` (ohne Schlüsselliterale), `Umstieg.php`; review-D F1/F2/O1.

## Gemeinsamer Lese- und Umstellungsvertrag

Das Werkzeug arbeitet auf einem isolierten Import aus Datenbankabzug (ADR 0003), nicht über einen öffentlichen Entschlüsselungsendpunkt. Keine Altlesefunktion wird durch REST/MCP/UI des neuen Kerns erreichbar.
ADR 0004 erlaubt ausschließlich die befristete v1-Headerübersetzung im isolierten
Docker-Adapter nach ../ingest/legacy-adapter.md; keine :1/CBC-Inhaltsausnahme. Schlüssel und Passphrasen sind nur flüchtige, ausdrücklich bereitgestellte Werkzeugeingaben; sie gehören nicht in Fixtures, Logs, Audit oder Exportberichte. Dieses Vertragspaket autorisiert weder produktive Migrationen noch die Ausführung des Altprojekts.

Erkennung: exakt `KUBUS-AEAD:2|` → strenger :2-Parser; erstes Segment exakt `KUBUS-AEAD:1` → :1; anderes `KUBUS-AEAD:`-Präfix → Versionsfehler; sonst nur der explizite Drei-Segment-CBC-Leser. `Chiffrate::version` im Altcode ist allein keine hinreichende Validierung. Ein beschädigtes versioniertes Paket darf nicht als CBC probiert werden.

Je importierter Zeile unter Sperre die Originalbytes/Identität erneut prüfen, alle belegten verschlüsselten Spalten (`data`, `file1Enc`, `mailBody`, `mailBodyFiller`) vollständig bearbeiten und gemeinsam transaktional ersetzen. Gültige bereits migrierte :2-Werte werden erkannt, nicht nochmals als Altformat gelesen. Klartextbytes werden unverändert neu nach :2/hpke für die bestätigte Kundengeneration verschlüsselt; kein JSON-Neuformatieren und kein Base64-Dekodieren von Mailtexten. Insbesondere ist alter Mailklartext häufig selbst Base64 von getrimmtem Text. Originalbytes bzw. gesicherter Abzug bleiben bis zur Abnahme für Wiederanlauf erhalten; keine destruktive Teilmigration.

Nicht entschlüsselbare Zeilen bleiben als Fehler mit stabiler Identität und sicherer Ursache im Migrationsbericht. Es gibt keinen „erfolgreich, aber leer“-Ersatzwert. `datenschluesselUmstiegAusnahme` und das alte Schlüsselprotokoll sind mit ihrer Bedeutung zu übernehmen: Ausnahmen machen Daten nicht entschlüsselbar. **OFFEN K10:** Koordination muss den Umgang mit nicht migrierbaren Ausnahmezeilen vor Cutover entscheiden. Sie dürfen nicht unbemerkt im aktiven Bestand verbleiben, weil die Laufzeit nur :2 liest. Gleichzeitige Rotation und Migration sind zu verhindern; das konkrete Sperr-/Checkpointverfahren ist im Migrationspaket zu prüfen.

## `KUBUS-AEAD:1`

```text
KUBUS-AEAD:1|b64(rsaKey)|b64(iv)|b64(ct)|b64(tag)
```

Genau fünf Segmente. Standard-Base64 mit PHP-`base64_decode(s,true)`-Kompatibilität; **kein** nachträglich eingeführter kanonischer Rückkodierungsvergleich. Ungültiges Decode ablehnen. Der Writer erzeugt CEK[32], IV[12], Tag[16]; der alte Reader prüft IV und Tag, aber nicht explizit die entpackte CEK-Länge. Die Behandlung abweichender CEK-Längen ist vor Portierungsfreigabe synthetisch zu prüfen, keine neue Toleranz erfinden.

1. Privaten Schlüsselstring mit bereitgestellter Passphrase über die kompatible Schlüsselbibliothek laden (`openssl_pkey_get_private` im Altcode). Fehlschlag beendet den Vorgang.
2. `rsaKey` mit RSA und explizitem `OPENSSL_PKCS1_OAEP_PADDING` öffnen.
3. AES-256-GCM mit dem erhaltenen Schlüssel, RAW-Chiffrat, IV[12], Tag[16], AAD exakt `ASCII("KUBUS-AEAD:1")` öffnen. Fehlschlag beendet den Vorgang.

**OFFEN K02 – RSA-OAEP-Hash:** Altcode setzt weder OAEP-Digest noch MGF1-Digest noch Label explizit. SHA-1 ist hier kein beschlossener oder getesteter Wert. Prüfauftrag: in isoliertem synthetischem PHP/OpenSSL-Harness tatsächliche Defaults für OAEP-lHash, MGF1 und Label bestimmen, mit explizit parametrisierter zweiter Implementierung gegenprüfen und PHP-/OpenSSL-Version festhalten. Erst dann feste Migrationsparameter freigeben.

**OFFEN K03 – PEM:** passphrasengeschützter Export ist belegt; RSA-PEM-Containertyp, Exportcipher, KDF und produktive RSA-Längen sind nicht belegt. Prüfauftrag: synthetischen Export entsprechend `bvk:scripts/kompat-test.sh:254–258` außerhalb des Altprojekts erzeugen und Container/Cipher/KDF dokumentieren; benötigte Importvarianten vor Cutover durch autorisierten Bestandsnachweis ohne Schlüsselveröffentlichung bestimmen. Weder PKCS#1 noch PKCS#8 noch RSA-2048 als pauschalen Produktionsvertrag annehmen. X25519-Hüllen sagen darüber nichts aus.

## CBC-Altpaket

```text
b64(rsaKey)|b64(iv)|b64(ct)
```

Genau drei Segmente, kein Präfix, Standard-Base64 mit derselben strikten PHP-Decode-Semantik ohne Kanonizitätsvergleich. RSA-OAEP wie oben; IV exakt 16 Byte; AES-256-CBC mit RAW-Chiffrat und OpenSSL-Standardpadding (PKCS#7). Kein MAC und kein Tag. Paddingerfolg beweist keine Integrität. Das Werkzeug muss den fehlenden Integritätsnachweis im Ergebnis ausweisen; keine nachträgliche Behauptung von AEAD-Authentizität. Entschlüsselungs-/Paddingfehler sperren die Zeile. Keine neue CBC-Erzeugung außerhalb synthetischer Fixtures.

## `MFAKEYv1|` und Klartext-Vorgänger

```text
MFAKEYv1|b64(iv[16])|b64(b64(CBC_RAW(secret)))
```

Dies ist ein eigener Typ und darf nicht dem Formularpaket-Dispatcher übergeben werden. Nach dem exakten Präfix Payload am ersten `|` in IV und Ciphersegment aufteilen (Altcode `explode(...,2)`). IV streng Base64-dekodieren, Länge 16 prüfen. Separat bereitgestellter MFA-Konfigurationsschlüssel wird streng aus Base64 dekodiert und MUSS 32 Byte haben. Ciphersegment einmal streng Base64-dekodieren; das Ergebnis ist der Base64-Ciphertext, den `openssl_decrypt(...,'AES-256-CBC',key,0,iv)` verarbeitet. Die Option `0` ist die zweite Base64-Schicht. Eine Portierung mit nur einer Schicht wäre inkompatibel.

Kein MAC; leeres entschlüsseltes Secret wird im Altleser abgelehnt. Fehlendes exaktes Präfix bedeutet beim alten MFA-Leser unveränderten Klartextbestand, nicht „versuche CBC“. Klartextbestand darf ausschließlich als explizit klassifizierter Migrationsfall verarbeitet werden. Migration 011 allein hat ihn nicht verschlüsselt (PARITAET/review-C).

**OFFEN K11:** Zielvertrag für serverseitig verwendbare MFA-Secrets mit P2-5 festlegen (Schlüsselhaltung, AEAD-Format, Version, Rotation, Importprüfung). Kein Wrappen als Formular-:2 unter einem nur im Browser verfügbaren `sk_D`: das würde den serverseitigen TOTP-Login unbenutzbar machen. Neue Laufzeit darf den Altleser nicht als Dauerlösung übernehmen.

## Rohe v1-Header-Schlüssel / historische Signalheader

```text
b64(IV[16] || HMAC-SHA256(ct, fullKey)[32] || ct)
```

AES-256-CBC mit RAW-Chiffrat, PKCS#7; HMAC umfasst nur `ct`, **nicht** den IV. Derselbe übergebene Schlüsselstring wird an AES und HMAC gegeben. Globale/v1-Schlüssel sind rohe Strings ohne Base64-Dekodierung; deren Werte werden hier weder gelesen noch übernommen. Formularbezogene v2-Schlüssel sind dagegen Base64 von genau 32 Rohbytes. **HMAC verwendet den vollständigen Rohstring**, keine aus AES vermutete Kürzung.

Historischer Reader: nicht-strenges `base64_decode`, dann IV/MAC/Rest abtrennen, CBC-Entschlüsselung vor MAC-Vergleich, `hash_equals` über MAC, bei passendem MAC Klartext mit `LF` anhängen, sonst leerer String. Aufrufer trimmt und nimmt den ersten nichtleeren Klartext; bei Entschlüsselungsfehler und dennoch passendem MAC ergibt PHP-Konkatenation ebenfalls keinen nutzbaren getrimmten Wert. Das Schreibformat darf nicht mit einer behaupteten alten MAC-vor-Decrypt-Prüfreihenfolge verwechselt werden. Ein neuer isolierter Reader darf keinen Klartext vor Abschluss seiner Prüfungen herausgeben.

Historische Reihenfolge je Signal: formularspezifisch aktuell, gültiger Vorgänger; dann global aktuell und akzeptierte Übergangsliste. Formularlookup-Fehler ergaben eine leere Liste und danach globalen Fallback. Vorherige Formularschlüssel gelten sieben Tage; Trefferweg nur dann `FORMULARSPEZIFISCH`, wenn UA und IP beide dort erfolgreich sind, gemischte Treffer zählen `GLOBAL`. Diese Beschreibung ist ein Migrationsprüforakel, keine neue Laufzeitfreigabe.

**OFFEN K01 – AES-Schlüsselkürzung:** Sichtbare Anwendung kürzt/hasht nicht. Prüfauftrag: synthetische 61-Byte-ASCII-Schlüssel mit gleichem 32-Byte-Präfix und verschiedenen Suffixen sowie kurze/genau 32/überlange Schlüssel in isoliertem PHP/OpenSSL-Harness prüfen; AES- und HMAC-Ergebnisse getrennt vergleichen. Bibliotheksquelle und Versionen belegen. „AES nutzt die ersten 32 Byte“ bleibt bis dahin unbestätigt; nicht als Migrationskonstante implementieren.

**K12 durch ADR 0004 H11 entschieden:** befristeter Docker-Adapter, kein
Altdecoder im Kern, keine globalen Schlüssel als Laufzeitfallback. Der
[Adaptervertrag](../ingest/legacy-adapter.md) legt Vertrauensgrenze,
formularbezogene Schlüssel, Ablauf/Widerruf und Abschaltung fest.
Laufzeit 90 Tage ist nur VORGESCHLAGEN; K01-/K13-Kreuzprüfung und sichere
Provisionierung bleiben vor Freigabe erforderlich.

## Vertragsrunde 4 — Hash über Chiffratbytes (M4, VORGESCHLAGEN)

Beim Altimport wird `stored_objects.payload_sha256` aus den dekodierten Bytes
iv‖ct‖tag des (nach `:2` überführten) Nutzchiffrats berechnet, nie aus dem
Base64-Text. Weil die Altleser Base64 ohne Rückkodierungsvergleich dekodieren, kann
dasselbe Chiffrat mehrere gültige Textdarstellungen haben; nur der Hash der Bytes ist
eindeutig. Siehe `../data/objektinventar.md` (M1–M4, Grenze von `payloadSha256`).

## P11-F: Browserstichprobe nach Import

ADR 0033 erlaubt im internen Migrationswerkzeug ausschließlich die lokale Probe
bereits migrierter :2/hpke-Objekte mit dem ausdrücklich im Browser eingegebenen
alten X25519-Schlüssel. Kein RSA-/CBC-/v1-Decoder im Kern und keine Übermittlung
von Klartext oder privaten Datenschlüsseln. Servernachweis ist nur eine menschliche
Bestätigung zum Chiffrathash; Testverschlüsselung und Rücklesen erfolgen lokal.
