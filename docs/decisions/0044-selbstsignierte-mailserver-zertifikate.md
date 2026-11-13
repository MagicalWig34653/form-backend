# ADR 0044: Selbstsignierte Zertifikate je Mailserver (Option kehrt zurück)

13.11.2026. Status: umgesetzt (Agent); Nutzerentscheidung von Lino per Nachricht übermittelt, Bestätigung in der App steht beim Review aus.
Todolino 734F1761-BABE-41B8-804F-5F6CC59D6F52. SPDX-License-Identifier: AGPL-3.0-only.
Ersetzt den Teil „`verifyCertificate:false` nur mit Entwicklungsschalter“ der SMTP-TLS-Härtung (Übergabe `docs/handoffs/SMTP-TLS-Haertung.md`, Merge 7885e98).

## Kontext

Das Altbackend kannte je Mailserver die Option „Eigene Zertifikate erlauben“ (`outgoingMailServer.SMTPallowSelfSigned`).
Lino: „Das hab ich damals mühevoll von Hand eingebaut“, nämlich für einen bestimmten Mailserver mit selbstsigniertem Zertifikat.
Die Härtung vom 11.11. sperrte `verifyCertificate:false` im Produktivbetrieb vollständig (nur mit `FORM_ALLOW_INSECURE_DEV`). Damit hätte der
Umstieg diesen Mailserver unbrauchbar gemacht.

## Entscheidung

1. **Option je Verbindung, kein globaler Schalter.** `connections.safe_config_json.verifyCertificate` (Standard `true`) darf für eine
   SMTP-Verbindung ausdrücklich `false` sein, auch ohne `FORM_ALLOW_INSECURE_DEV`. Nur ein echter Boolean zählt, alles andere ist ungültig (422).
2. **Verschlüsselung bleibt Pflicht.** `security: plain` bleibt nur mit Entwicklungsschalter möglich und lässt sich nicht mit der Option
   kombinieren (Klartext ist etwas anderes als selbstsigniert; im Altbackend gab es nur die Zertifikatsoption). TLS/STARTTLS wird erzwungen,
   kein Rückfall auf Klartext (`starttls_unsupported`). Der Zielschutz (HostGuard) bleibt unverändert.
3. **Recht und Audit.** Anlegen und Ändern verlangen wie jede Verbindung das Systemrecht `system.manage` mit frischer Anmeldung; ein
   feineres Recht ist nicht nötig. Jede Abschaltung schreibt `connection.tls-verification-off`, jedes Zurückschalten `connection.tls-verification-on`
   (Kategorie `mail`, Verbindungs-ID als Subjekt, keine Details, kein Host, keine Geheimnisse). Zurückschalten: `PUT /connections/{id}/tls-verification`
   mit `{"verifyCertificate": true|false}` (nur SMTP; 404 unbekannt, 422 anderer Typ/Wert; ohne Wertänderung kein Audit).
4. **Import.** Der Altwert `SMTPallowSelfSigned = 1` wird `verifyCertificate:false`. Nur der ausdrückliche Wert 1 zählt (Hotfix im Altprojekt,
   Branch `hotfix/smtp-selfsigned`: das alte Formular speicherte für „nicht gesetzt“ den Wert 2, und jeder Wert außer 0 schaltete die Prüfung ab).
   0, 2, leer, NULL und Unbekanntes bedeuten: Zertifikat prüfen. Die Quellprüfung (Plan) markiert betroffene Server (`verifyCertificateOff`), der
   Umstieg zeigt „Zertifikatsprüfung für diesen Mailserver abgeschaltet übernommen“.
5. **PWA.** Schalter „Eigene/selbstsignierte Zertifikate erlauben“ (nie vorbelegt) mit Warnhinweis, Kennzeichnung „Zertifikat wird nicht geprüft“
   in der Verbindungsliste, Menüpunkt „Zertifikatsprüfung wieder einschalten“.

## Beibehalten aus der Härtung

Standard bleibt: Zertifikat und Hostname werden geprüft. Bei IP-Literalen kein SNI, Abgleich der verbundenen Adresse gegen die IP-SAN (nie CN).

## Risiko

Ohne Prüfung kann ein Angreifer im Netzpfad Mails mitlesen oder verändern und Zugangsdaten abgreifen. Deshalb: nur je Verbindung, sichtbar
gekennzeichnet, auditiert, nur für bekannte Server (eigenes Netz).
