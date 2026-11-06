# ADR 0026: Missbrauchsschutz am Eingang

Status: beschlossen durch Nutzerauftrag, 03.11.2026. Sprache gemäß ADR 0001.

## Vertrag und Begründung

`form.security.abuse` enthält optional `siteKey`, `failPolicy` (`open` als
Standard oder `closed`) und `testMode` (Standard false). Änderungen folgen der
bestehenden Entwurfs-/Veröffentlichungsstrecke mit live geprüften Rechten.
Secrets stehen ausschließlich im SecretStore; die formulargebundene Referenz liegt
in `form_abuse_secrets`. GET/PUT
`/admin/api/v1/tenants/:tenantId/forms/:formId/abuse-secret` verlangen eine frische
menschliche Sitzung und `draft.write`, PUT zusätzlich CSRF/Origin. Das Secret gilt
sofort, ist nie lesbar und wird bei Ersetzung im selben Commit ausgetauscht.
Audit enthält nur Aktion und Objektbezüge, keine Werte, IP, UA, Token oder Hashes.

Die Prüfung erfolgt nach Signatur/Replay und vor Verschlüsselung/Seiteneffekten.
So verbraucht ein erfolgreicher Replay kein zweites Turnstile-Token. Cloudflare-
Siteverify ist der einzige Captcha-Endpunkt (10 s Deadline, keine Weiterleitungen).
Ein fehlendes/negatives Token ist `rejected` (412), Netzwerk-/HTTP-/Format- oder
Secretfehler sind `unavailable` (fail-open mit Markierung oder fail-closed 503).
Quelle: https://developers.cloudflare.com/turnstile/get-started/server-side-validation/
Bei gleichzeitigen identischen Erstversuchen können zwei Siteverify-Aufrufe
entstehen; nach abgeschlossener Annahme ist der Replay garantiert lokal.

Testmodus stammt ausschließlich aus der veröffentlichten Policy, niemals aus
Eingabefeldern/Headern. Er blockiert Captcha-/IP-Regeln nicht, markiert Einsendungen
als `test`, erzeugt keine Produktionsstatistik/Webhooks und führt eigene Abläufe
nicht aus. Standardmail bleibt möglich, aber nur mit expliziter Empfängerfreigabe.
Malware-Treffer werden auch im Testmodus nicht angenommen oder zugestellt.

## Einstellungen und Status

ADR 0021 gilt unverändert: ENV > DB > Default, alle neuen Werte live über die
bestehende `system.settings`-API; deren Audit protokolliert nur Schlüsselnamen.
`abuse.blockedNets` enthält lokale IPs/CIDRs (auch gepflegte Tor-Adressen),
`abuse.uaPatterns` eine JSON-Liste literal und ohne Regex interpretierter,
case-insensitiver Teiltexte. Keine Downloads, URL- oder Importfunktion vorhanden.
`abuse.hashes` ist eine lokale Liste kleingeschriebener SHA-256-Werte.
Listen sind auf 4096 Bytes/200 Einträge begrenzt. Ungültige Werte werden abgelehnt.

`abuse.threshold/windowSeconds/banSeconds` haben Standard 5/600/7200. Negative
Captcha-, Blocklisten- und Malwaretreffer zählen als Missbrauch; Dienstausfälle
nicht. Die atomare formulargebundene IP-Zählung nutzt einen zweckgetrennten HMAC
mit Betriebsserver-Schlüssel und kanonisierter, vertrauenswürdig aufgelöster IP.
Keine Roh-IP/UA-Persistenz. Abgelaufene Fenster/Sperren beginnen neu. Abgelaufene
Zeilen werden bei weiteren Missbrauchstreffern aufgeräumt; ohne Verkehr verbleiben
Pseudonyme bis zur nächsten Bereinigung/Formularlöschung. Kein Ban-Management-UI.

Lokale Hashprüfung liefert `hash_clear` (kein Treffer in der konfigurierten Liste,
keine Garantie auf Schadsoftwarefreiheit). Ohne aktive Liste oder bei optionalem
Scannerfehler bleibt `nicht_geprueft`; ohne Upload `none`. Die Dienstschnittstelle
`MalwareHashScanner` bekommt nur SHA-256, keine Datei; kein Dienst wird angebunden.
Ein Treffer ergibt 415 vor Speicherung/Versand.

`submissions.captcha_status`, vorhandener `malware_scan_status` und `environment`
bleiben über Einsendungs-API/PWA sichtbar; Annahme und Replay liefern dieselben
Statusmarker in `X-Form-Captcha/Malware/Mode`. Testwarnungen sind deutsch.
`mail.restricted=true` erzwingt die Empfängerschranke auch produktiv.
`mail.allowedRecipients` ist eine exakte, case-insensitive Adressliste (JSON).
To/BCC/Bestätigung werden gemeinsam geprüft; leere Freigabe sperrt alles.
Prüfung beim Vorbereiten, Resend und unmittelbar vor Transport verhindert einen
Umweg über eigene Abläufe oder zwischenzeitlich geänderte Einstellungen.

## Schema und Grenzen

Baseline enthält neue Tabellen und Captcha-Spalte; Bestandsupgrade separat unter
`backend/db/upgrades/0026-ingest-abuse.sql`. Keine produktive Migration ausführen
oder Baseline-Prüfsummen überschreiben. Splitter-Zähler: 78 Tabellen.
DB-Nebenläufigkeit, Rechteentzug/Audit, SMTP-/Proxy- und reale Cloudflare-/Browser-
Abnahme bleiben bis zu den separat auszuführenden Integrationsprüfungen offen.
