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
