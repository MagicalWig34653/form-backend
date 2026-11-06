# ADR 0010: Mailversand mit Inhalt (31.10.2026)

**Nutzerentscheidung:** Die Mail soll – wie im Altsystem – auch den Inhalt der Einsendung enthalten können.

## Folge für das Sicherheitsmodell
Der Server versiegelt Einsendungen beim Eingang; der Klartext liegt dort ohnehin kurz im Arbeitsspeicher. Mails mit Inhalt werden **aus diesem Speicher** gerendert und versendet. Der Klartext wird für die Mail **nirgends gespeichert** (keine Mail-Warteschlange mit Inhalt, kein `mailBody` in der Datenbank). Der Inhalt verlässt den Server aber im Klartext Richtung Mailserver und Empfänger (SMTP über TLS bzw. HTTPS zum Proxy); ab dann gilt der Schutz der Mailkette, nicht mehr der der Datenbank. Das ist dokumentiert und pro Formular nur aktiv, wenn `form.mail` konfiguriert ist.

## Entscheidungen
1. **Konfiguration** liegt im Formular (`form.mail`, Teil des veröffentlichten, unveränderlichen Release): Absender, Organisationsmail (Empfänger, BCC, Betreff, Text, Antwortadresse aus Feld), Bestätigungsmail (Empfängeradresse aus Feld, Betreff, Text). Platzhalter wie im Altsystem `#=[Feldname]=#`. Bestätigung und Organisation sind unabhängig schaltbar (wie `MailVersandArt`).
2. **Verbindungen** (`connections`: `smtp`, `mail-proxy`) verwaltet ein Systemadministrator (`system.manage`, frische Anmeldung); Passwort/ACODE liegen verschlüsselt im `SecretStore`. Ein Kunde nutzt nur Verbindungen, die ihm zugeordnet sind (`customer_connections`); ein Formular wählt eine davon (`form_connections`, Zweck `mail`, Umgebung `production`).
3. **Transporte:** SMTP (SMTPS oder STARTTLS, AUTH PLAIN/LOGIN, Zertifikat- und Hostprüfung standardmäßig an, Klartext nur mit `FORM_ALLOW_INSECURE_DEV`) und der **Altsystem-Mail-Proxy** (HTTPS-POST mit Header `ACODE`, base64-Felder; Erfolg nur HTTP 200).
4. **Zielschutz (SSRF):** Verbindungsziele werden beim Anlegen und bei jedem Versand aufgelöst; Loopback, private, Link-Local- und Metadaten-Adressen sind gesperrt, außer Netze aus `FORM_MAIL_ALLOWED_NETS` (CIDR-Liste). Der Admin ist vertrauenswürdig, der Schutz ist Tiefenverteidigung.
5. **Zustellung:** Beim Eingang werden die Zustellzeilen (`mail_deliveries`, Identität Einsendung + Umgebung + Art) in derselben Transaktion wie die Einsendung angelegt (Wiederholung mit gleichem `Idempotency-Key` erzeugt keine zweite Mail). Versand nach der Antwort an den Absender, mit Zeitlimit. Erfolg = `smtp-accepted`; Fehler = `waiting-manual` mit Fehlercode und Versuchszähler. **Kein automatischer Wiederholversand** (ADR 0002 Nr. 19: kein Klartext für Retries auf dem Server). Ein Absturz nach Commit hinterlässt `pending`/`leased`, das nach Ablauf der Lease als `uncertain` gilt. Manueller Wiederversand setzt die Entschlüsselung im Browser voraus und ist **noch nicht umgesetzt**.
6. **Abweichungen vom Altsystem (bewusst):** Feldwerte werden in HTML-Mails **HTML-escaped** (Altsystem: kein Escaping); Adressen werden streng geprüft (ASCII, kein CR/LF); Kopfzeilen können nicht injiziert werden; Betreff nur Text ohne Zeilenumbrüche; alle Empfänger müssen angenommen werden, sonst wird vor `DATA` abgebrochen (kein Teilversand).
7. **Antwort an den Absender:** Die Einsendung gilt als angenommen (200), unabhängig vom Mailergebnis; der Mailstatus ist nur für Administratoren sichtbar (`GET …/mail-deliveries`, ohne Inhalt).

## Nicht Teil
Anhänge (Uploads fehlen noch), Test-/Produktionsempfänger-Trennung und Empfängerschranke (`MailGuard`), Webhooks, Mail-Editor, manueller Wiederversand.
