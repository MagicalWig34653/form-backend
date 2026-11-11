# 0002 Sicherheit und Cutover (P1, Teil 2)

Datum: 26.10.2026. Status: **beschlossen durch den Nutzer** (Auswahl der jeweils empfohlenen Option in der Session vom 26.10.2026). Ergänzt 0001.

| Nr. | Entscheidung                                                                                                                                                                                                               | Alternative (verworfen)        |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| 15  | Ed25519-Signatur v2 ist Pflicht. Altformulare ohne Public Key bekommen einen Schlüssel provisioniert; eine Ausnahme ist je Formular zeitlich begrenzt, protokolliert und widerrufbar.                                      | Optional wie Altbestand        |
| 16  | Passwort-Login mit Fehlversuchs-Lockout und Backoff (je Konto und IP) sowie Rate-Limit für alle Admin-Routen; Passkey bevorzugt. Konkrete Schwellen offen.                                                                 | Nur Rate-Limit und Protokoll   |
| 18  | Vor Cutover Quiesce der Zustellungen; verbleibende Einträge (`mailZustellung`, `webhookOutbox`) werden mit stabiler Identität übernommen, keine Doppelzustellung. Mit `fehlgeschlagen` als offenem Status, siehe review-C. | Verwerfen und neu auslösen     |
| 19  | Mail-Cron wie Altbestand: fällige Wiederholungen melden, Versand nur per manuellem Resend durch Benutzer mit Passphrase. Kein Klartext für automatischen Retry auf dem Server.                                             | Automatischer Wiederholversand |

## Folgen

- Pflicht-Signatur: Der Vertrag (P2) beschreibt Provisionierung, Ausnahmefrist und Ablehnung ohne Signatur. Kanonisierung der Signatur ist an den Altcode (`json_encode` ohne Slash- und Unicode-Escaping) gebunden, solange Alt-SDKs weiterlaufen.
- Nr. 4 (Klartextpersistenz für Retry) ist durch Nr. 19 weitgehend beantwortet: keine Klartextpersistenz zum Zweck automatischer Wiederholung. Weitere Aspekte (Recovery, Granularität) offen.
- Cutover-Probe (P9) muss Quiesce und Identitätserhalt (026: UNIQUE auf Zustellidentität) nachweisen.

## Offen

Nr. 5–13 und Rest von 4, 12, 14 sowie Schwellen für Lockout/Rate-Limit.
