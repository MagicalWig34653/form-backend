# Weg zur Ablösung des alten Backends

Stand 02.11.2026. Ehrliche Einschätzung, keine Terminzusage; Pflege bei jedem Paketabschluss.

## Bereits belegt (lokal getestet, nicht produktiv)
Verschlüsselter Eingang (Signatur, Idempotenz, Uploads), Mail mit Inhalt und manuellem Resend, PHP-SDK mit Datei-Upload und Selbstupdate (FTP/FTPS/SFTP, Rollback, optionale Automatik), Passkey-Login mit Zweitfaktor, Rechte/Konten/Passkeys, Verwaltungsoberfläche, Browser-Entschlüsselung mit Schlüsselverwaltung (PRF, Recovery), Statistik (tägliche Zählung), Docker-Image amd64/arm64, CI, Swarm-Stack.

## Blocker (Reihenfolge nach Abhängigkeit)
| Nr | Paket | Inhalt | Abhängigkeit |
| --- | --- | --- | --- |
| 1 | P8 Parität | Funktionen aus `docs/PARITAET.md` gegen den Neubau abhaken: Webhooks, Export, Löschung/Aufbewahrung, Haltesperre (Hold), Debug, Test-Ziele, MCP/Tokens, S3/SFTP-Speicher, Domainzuordnung (P7), Statistik-Ereignisse | Nutzer prüft Prioritäten |
| 2 | P6 Ablaufengine | Bausteine, Bedingungen, Ablaufeditor, Debug; Skripte erst in P6-S (Isolation) | Verträge `contracts/flow` |
| 3 | Rotation | Neue Datenschlüsselgeneration, Umhängen aller Pakete im Browser, Abschluss; macht Zugangsentzug final | Keyring |
| 4 | P9 Migration | Import der Altdaten (Kunden, Formulare, Einsendungen, Statistik, Passkeys), Rewrap, Paritätsprüfung, Cutover-Probe; **braucht Zugriff auf eine Kopie der Altdaten**; Cutover-Voraussetzung: alle Kunden auf dem neuen SDK (ADR 0006) | 1–3 |
| 5 | P10 Betrieb | Lasttest, Mehrreplika/Wiederanlauf, Backup und Restore-Probe, Monitoring, echter Swarm-Betrieb | 1–4 |
| 6 | Externe Prüfung | Unabhängiges Sicherheitsaudit (Krypto, Auth, Ingest), Browser-/Geräte-Matrix (Safari, Firefox, echte Authenticatoren) | 1–5 |

## Früher Meilenstein
Pilotbetrieb mit einem **neuen** Kunden ohne Migration (alles Notwendige für diesen Weg ist grundsätzlich vorhanden): Betrieb hinter Reverse Proxy, Mail-Verbindung, Kundenschlüssel, SDK-Einbau. Voraussetzung: Backup-/Restore-Probe, Monitoring, externe Kurzprüfung der Eingangs- und Anmeldepfade.

## Was nur der Nutzer entscheiden/liefern kann
Zugriff auf Altdaten-Kopie für P9 (ohne echte Schlüssel ins Repo), Priorisierung der Paritätsfunktionen, Zielumgebung (Swarm, Domains, E-Mail-Server), Zeitpunkt/Fenster des Cutovers, Beauftragung eines externen Audits.
