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
