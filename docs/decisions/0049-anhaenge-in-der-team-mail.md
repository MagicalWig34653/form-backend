# ADR 0049: Hochgeladene Dateien hängen an der Mail an das Team

Status: Entscheidung von Nutzer (Lino) am 14.11.2026. Löst den Teil „Anhänge existieren in Mails noch nicht“ aus ADR 0041 ab (0041 bleibt im Übrigen gültig). Ergänzt ADR 0010. Todolino 3B69EBC5 (Migrationsblocker).

## Anlass

Feature-Matrix ALT/NEU (14.11.2026): Das Altsystem hängt den Upload an die Organisationsmail (`providers/formulare/generisch.php`, `anhaenge()`; Mail-Proxy: `mailAttachment`/`mailAttachmentName`). Das neue Backend schickte keine Anhänge, ADR 0041 hielt das ausdrücklich fest („Anhänge existieren in Mails noch nicht“) und verwies das Team auf das Backend. Entscheidung des Nutzers:

> „anhänge müssen in die Mail. Das Team hat keinen Zugriff zum Backend! Der Prozess muss beim neuen Backend für die Praxis gleich sein.“

## Entscheidung

- Die Mail an das Team (Art `organisation`, Inhalt `full`) trägt alle hochgeladenen Dateien der Einsendung als Anhang: gleiche Empfänger, gleicher Betreff und Text, gleicher Dateiname wie hochgeladen, Typ aus dem Upload. Die Bestätigungsmail an die einsendende Person trägt nie einen Anhang (wie ALT). Die Benachrichtigungsmail (`content: notification`) trägt keinen Anhang (bewusste Wahl je Formular, enthält keine Angaben).
- Aufbau: `multipart/mixed` mit dem unveränderten Textteil (Base64, UTF-8) und je Datei einem Base64-Teil mit `Content-Disposition: attachment`. Ohne Anhang bleibt die Mail byte-gleich zur bisherigen einteiligen Form.
- Klartext: Die Dateien liegen im Ingest-Request bereits im Speicher (vor dem Versiegeln, derselbe Weg wie die Feldwerte für den Mailtext). Sie werden nur im Speicher an die Mail gereicht (`MailAttachment`, `Data` copy-on-write, keine zweite Kopie bis zum Aufbau der Sendedaten), nie in `mail_deliveries`, nie in Logs (Logs tragen nur Kennung, Zustand und Fehlertoken), nie auf Platte. Die gespeicherten Objekte bleiben verschlüsselt (HPKE/Kundenschlüssel) wie bisher.
- Dateiname: Steuerzeichen (auch CR/LF, NUL, Unicode-Zeilentrenner, Bidi-Steuerzeichen), `/`, `\` und `"` werden entfernt bzw. ersetzt, Länge höchstens 255 Byte, leer wird `anhang`. Nicht-ASCII-Namen erhalten RFC-2231/5987-Parameter (`filename*=UTF-8''…`) plus ASCII-Rückfall (Umlaute transliteriert); Header bleiben 7-bit.
- Content-Type: der serverseitig erkannte Typ des Uploads (nicht der deklarierte), nur schlichtes `typ/untertyp`; Text-, HTML-, XML-, `multipart/`- und `message/`-Typen werden zu `application/octet-stream` (nie aktiver Inhalt). Erlaubt sind am Eingang ohnehin nur pdf/png/jpg/jpeg/heic/heif.
- Grenzen: Gesamtgröße einer Mail (Sendeform inkl. Base64) höchstens `FORM_MAIL_MAX_MB` (Standard 30, Bereich 10 bis 100). 30 MiB tragen einen Anhang von 19,9 MB (Base64 ≈ 26,9 MB) samt Text. Der Wert muss zum Limit des Mailproviders passen (Betreiber setzt ihn niedriger, wenn der Provider weniger annimmt). Höchstens 5 Dateien (Upload-Limit), beim Mail-Proxy 1 (Protokoll kennt ein Feld).
- Zu groß, nie still verloren (Altverhalten: ALT kennt kein eigenes Limit, die Mail scheitert beim Provider mit Fehler und `registerError`; das ist kein Vorbild): Passt eine Datei nicht mehr (Reihenfolge des Uploads, später kleinere Dateien dürfen noch passen), wird sie nicht angehängt, die Mail nennt sie mit Name und Größe samt Größenlimit und dem Hinweis, dass sie in der Einsendung im Backend abrufbar ist, und die Zustellzeile erhält `last_error_code = attachments_omitted` bei Zustand `smtp-accepted`. Die Mail geht also immer raus (Praxisteam bekommt Angaben und Hinweis), das Weglassen ist in Mail und Status sichtbar.
- Wiederversand und verzögerte Flow-Mails: Dort liegen die Dateien nicht im Speicher (der Wiederversand hält nur den Schlüssel des Datenobjekts, nicht der Anhänge; eine Flow-Mail entsteht nach dem Eingang). Diese Mails nennen die vorhandenen Anhänge nur mit einem Hinweis (Anzahl, „nicht beigefügt“) und erhalten ebenfalls `attachments_omitted`. Abweichung zu ALT: ALT hängt beim Wiederversand die entschlüsselte Datei an (`AnfrageResend`). Folgekarte: Wiederversand mit Anhangsschlüsseln (Browser entschlüsselt, reicht die Inhaltsschlüssel der Anhänge).
- Speicher (1024-MiB-Container; bis 14.11.2026: 512 MiB): Die Sendedaten (Base64 ≈ 1,36-fach, zusätzlich der Puffer der Verbindung) entstehen erst beim Senden; höchstens 2 Sendungen mit Anhang gleichzeitig, höchstens 64 MiB Anhangsbytes warten; darüber geht die Mail nach `waiting-manual` (`busy`, manuell wiederholbar) statt den Container zu füllen. Das BodyBudget des Eingangs (ADR „Body-Gate“) bleibt davor unverändert.
- Mail-Proxy: Das Altprotokoll bleibt (`mailAttachment` = Base64 der Bytes, `mailAttachmentName` = Base64 des Namens, ACODE-Header, HTTP 200). Neu: Der Proxy-Transport füllt beide Felder (bisher leer). Das Proxy-Protokoll kennt genau einen Anhang; weitere Dateien gelten als nicht angehängt (siehe oben). Der Proxy rendert immer HTML (`mailBody`), unverändert.

## Folgen

- Mailgröße steigt auf bis zu `FORM_MAIL_MAX_MB`; SMTP-Latenz je Mail mit 19,9 MB ist höher (Zeitgrenzen der Verbindung bleiben).
- Die Grenze gilt je Mail, nicht je Datei. Provider mit 25-MB-Limit: `FORM_MAIL_MAX_MB=25` setzen, dann erscheint eine 19,9-MB-Datei als genannt, nicht angehängt.
- Datenschutz: Die Datei verlässt das System unverschlüsselt per Mail zum Team, wie im Altsystem und wie der Mailtext mit Angaben (ADR 0041). TLS zum Mailserver ist Pflicht (ADR 0010).

## Nicht Teil

- Anhänge in Flow-Mails, Anhänge in Bestätigungsmails, Anhangsauswahl je Mailvorlage.

## Nachtrag 14.11.2026: Wiederversand mit Anhängen

Befund im Altsystem (`providers/AnfrageResend.php`, `ausKlartext(..., $anhangInhalt, $anhangName, ...)`; `formulare/generisch.php`: `anhaenge()` hängt beim Resend die vom Browser entschlüsselte Datei an): ALT hängt Anhänge beim Wiederversand an. ALT kennt keine Flow-Mails.

- NEU: `POST .../entries/{id}/resends` nimmt optional `attachmentKeys: [{ordinal, contentKey}]` (höchstens 16, je 32 Byte base64url, Ordinal einmalig; sonst 422). Der Browser liefert die Schlüssel (er entschlüsselt die Anhangspakete ohnehin lokal), der Server öffnet nur die eigenen gespeicherten Objekte im Speicher, prüft den SHA-256 gegen die signierten Metadaten der Einsendung, nimmt Name aus den signierten Metadaten und Typ aus der Endung (Upload-Allowlist). Klartext nie in DB/Logs/Audit; Schlüssel nie gespeichert.
- Grenzen wie oben: `FORM_MAIL_MAX_MB` (Öffnen stoppt, wenn der Klartext allein das Mail-Limit überschreitet), Passform und Sendetor (2 Sendungen, 64 MiB wartend, sonst `busy`/`waiting-manual`), Mail-Proxy 1 Anhang. Nur Mail an das Team im Inhaltsmodus `full`.
- Nie still: fehlender Schlüssel, fehlendes Objekt, falscher Schlüssel, Hash-Abweichung oder Überschreitung des Limits führen zu „nicht beigefügt“ im Mailtext plus `attachments_omitted`; die Mail geht trotzdem raus.
- Flow-Mails: kein Gegenstück in ALT, nicht wiederholbar (409, kein unveränderliches Manifest) und ohne Bytes im Speicher; bleiben bei Hinweis + `attachments_omitted`. Der Abschnitt „Wiederversand und verzögerte Flow-Mails“ oben gilt nur noch für Flow-Mails.
