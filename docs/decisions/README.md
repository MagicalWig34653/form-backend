# Architekturentscheidungen

Noch keine detaillierten Implementierungs-ADRs beschlossen. Bestätigte Produktvorgaben stehen in ANFORDERUNGEN.md; offene Entscheidungen in OFFENE-ENTSCHEIDUNGEN.md.

Vorlage je Entscheidung `NNNN-kurztitel.md`:

- Titel, Datum, Status (vorgeschlagen/beschlossen/ersetzt).
- Kontext und konkrete Anforderung.
- Entscheidung und betrachtete Alternativen.
- Folgen für Sicherheit, Kompatibilität, Betrieb und Migration.
- Prüfkriterien und offene Grenzen.

Eine Agent-Empfehlung wird nicht allein durch Ablage zum Nutzerbeschluss.

- [ADR 0022: Listenerabhängiger Zweitfaktor](0022-listener-abhaengiger-zweitfaktor.md) — P11-G, interne UV-Passkey-Anmeldung und öffentliche Passwortpflicht.

- [ADR 0026: Konten und TOTP](0026-konten-totp.md) — öffentlicher Alternativweg, kontoweite Sperre, Secret-Rotation und Kontostatus.

- [ADR 0036: Ingest-Budget je Client und Aktivschalter](0036-ingest-budget-und-aktivschalter.md) — FA-015 (`ingest.requestsPerMinute`) und FA-021 (`PUT forms/{id}/active`).

- [ADR 0037: Passkey-Step-up auf der Seite](0037-passkey-step-up.md) — `auth/reauth/{options,verify}`, Frische ohne Neuanmeldung, Lesen von Umstiegsstatus/Einstellungen ohne Frische.
- [ADR 0038: Übernahme des Alt-Kundenschlüssels im Browser](0038-altschluessel-uebernahme.md) — privater X25519-Altschlüssel oder importierte Alt-Recovery-Hülle, Selbstzugang ohne neuen Endpunkt.
- [ADR 0039: HTML-E-Mail-Builder im Mail-Reiter](0039-html-mail-builder.md) — MJML-Bausteine, Rich-Text, Quelltext; Speicherformat des Altsystems.
- [ADR 0040: Umstiegsplan automatisch aus der Quellprüfung](0040-umstieg-plan-automatisch.md) — Schlüssel-/kid-Metadaten, Formular- und Verbindungsnamen; Formulare, Kunden, Namespace, Verbindungen, Schlüssel und Generationen ohne Handeingabe.
- [ADR 0041: Inhalt der Mail an das Team](0041-mailinhalt-minimieren.md) — Standard „mit allen Angaben“ (`content: full`, wie Altbackend, auch ohne Vorlage als Feldliste); `notification` nur als bewusste Wahl; keine Warnung, kein Audit (Entscheidung Nutzer 13.11.2026) `release.mail-fulltext`.
- [ADR 0042: Härtung von SDK-Selbstupdate und Eingang](0042-sdk-deploy-haertung.md) — Konto-Lock, Überschneidungsverbot, Zielrevision, Laufphasen/`repair_required`, Ingest-Gate, Sitzungsfristen, strikter Multipart-Parser (Review Astra 2 Rest).
- [ADR 0043: Einmal-Snapshot mit Schreibpause-Prüfung im Code](0043-einmal-snapshot-quiesce.md) — kein Delta; Quellen-Fingerabdruck (CHECKSUM TABLE + COUNT) im Prüflauf, vor und nach dem Import; `source_changed`, `source_not_quiesced`, `snapshot_changed`; Job-Aktion `rehearse`.
- [ADR 0044: Selbstsignierte Zertifikate je Mailserver](0044-selbstsignierte-mailserver-zertifikate.md) — Option je Verbindung (`verifyCertificate:false`) produktiv erlaubt, TLS Pflicht, Audit, Import übernimmt `SMTPallowSelfSigned = 1`; ersetzt die Dev-Sperre der SMTP-TLS-Härtung.
- [ADR 0045: Eigentümer je API-Host](0045-api-host-eigentuemer.md) — `owner_customer_id`; Fremde erhalten 404 (kein Existenzorakel), kein Anhängen/Schalten fremder Hosts außer `system.manage`; Upgrade 0036 ordnet Bestand zu; Squatting ohne DNS-Nachweis bleibt Grenze.
- [ADR 0048: Signierte Besucher-IP vom SDK](0048-signierte-besucher-ip.md) — `X-Kubus-Client-IP` + Ed25519-Anspruch gebunden an die Request-Signatur; Sperre/Budget je Besucher (/64) nur bei gültiger Signatur, sonst Peer; Obergrenze `ingest.peerRequestsPerMinute`; Proxy-Vertrauen im SDK nur über `trustedProxies`.
- [ADR 0046: Feldmuster mit linearer Regex-Engine](0046-regex-linear-zeitgarantie.md) — eigener NFA-Matcher mit eingeschränktem Dialekt statt ICU; Prüfung beim Speichern und bei der Einsendung; kein ReDoS (S2-03).
- [ADR 0049: Hochgeladene Dateien hängen an der Team-Mail](0049-anhaenge-in-der-team-mail.md) — löst die Anhangsaussage von ADR 0041 ab (Entscheidung Lino 14.11.2026, Praxisteam ohne Backend-Zugang); multipart/mixed, RFC-2231-Dateinamen, `FORM_MAIL_MAX_MB` (30), zu große Dateien in Mail genannt + `attachments_omitted`, Speichergrenze, Mail-Proxy 1 Anhang; Wiederversand mit Anhängen (Nachtrag: Browser reicht `attachmentKeys`); Flow-Mails nur Hinweis.
- [ADR 0050: Replay im 300-s-Fenster (SEC-037)](0050-ingest-replay-signaturverbrauch.md) — Konzept (Vorschlag): Signaturverbrauch je (Formular, Signatur-Hash) speichern, gleiche Signatur mit anderem/fehlendem Key 409; braucht Migration, nicht umgesetzt.
