# ADR 0007: Umfang P5-B (30.10.2026)

Nutzerentscheidungen zum Paketvertrag `docs/handoffs/P5-B-paket.md`:

1. Entwürfe schreiben in P5-B nur Admin (Rechtegruppen/Vorlagen für Betreuer/Kunde später).
2. Zweiter Faktor nach Passkey ist in P5-B Pflicht (Login-Abschluss vollständig nach Vertrag `contracts/auth/anmeldung.md`).
3. Schemaänderung für Entwürfe (Drafts-Tabelle) per Vertragsergänzung erlaubt; danach `backend/db/check.sh` wiederholen.
4. B1 (Auth-Kern, `FormAuth`) läuft strikt vor B2 (Formulare/Release, `FormAdmin`).

Folge: Vor B1 schließt ein Architect die Vertragslücken E1–E8 aus dem Paketvertrag (Drafts-Tabelle, Passkey-Übernahme aus poc-passkey, Login-Abschluss mit 2. Faktor, Fehlerhülle `authentication_failed` mit Retry-After, Kanonisierungs-Hash, Rechtekatalog-Seeding, Release-Umfang, Zeitkanäle); nicht entscheidbare Punkte werden als offene Fragen gemeldet.
