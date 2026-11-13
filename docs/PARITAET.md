# Paritätsmatrix des Altbestands (P0)

Stand 26.10.2026. Einstieg und Korrekturstand zu den Teilberichten unter `docs/paritaet/`. Rein statische Lektüre des Altprojekts (`form-backend_bvk`), nichts ausgeführt, keine Datenbank, keine Produktionsdaten. Keine Aussage zur Produktionsreife. Die Teilberichte sind Stichproben-geprüft, nicht vollständig verifiziert.

## Teilberichte und Reviews

| Teil                              | Bericht                           | Unabhängiges Review                                        | Gesamturteil                                                                                                     |
| --------------------------------- | --------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| A Routen, Handler, Rechte         | `paritaet/A-routen-handler.md`    | `paritaet/review-A.md` (22 bestätigt, 3 falsch, 3 fehlend) | tragfähig; Korrekturen F01–F03 und Ergänzungen M01–M03 offen einzuarbeiten                                       |
| B Funktionen, Felder, Validierung | `paritaet/B-funktionen-felder.md` | noch keins                                                 | ungeprüft                                                                                                        |
| C Daten, Migration                | `paritaet/C-daten-migration.md`   | `paritaet/review-C.md`                                     | nur als Tabellenübersicht nutzbar; **Vertragsdetails stehen in review-C** (Spalten, Enums, FKs, Indizes, Runner) |
| D Krypto, Protokolle              | `paritaet/D-krypto-protokolle.md` | `paritaet/review-D.md` (27 Stichproben)                    | überwiegend richtig; Korrektur W13/§14.5, W5 und W12 nicht belegt, W7/W11 abgrenzen                              |

Modellhinweis: Codex-Aufträge wurden mit `--model gpt-6.1-sol` gestartet, liefen ohne Limit-Fehler; die Ausgaben nennen das Modell nicht, ob es tatsächlich lief, ist unbestätigt.

## Verbindliche Korrekturen an den Teilberichten

- **A:** Ed25519-Zeilenbelege in A:46/203 aktualisieren (`AnfrageSignatur.php:50-52`, `:101-102`, `:109`, `:120-124`). Passkey-Fehler nicht pauschal 401: unbekannte Aktion 400, Rate-Limit 429. Idempotenzschlüssel: Grenze 190 **Byte** nach Trimmen. Zusatz: Skripte sind auch direkt adressierbar, statische PWA-Pfade (`/manifest.webmanifest`, `/sw.js`, `/src/*`) ohne Sessionprüfung; die Docker-nginx-Varianten enden mit `=404` statt Login-Fallback.
- **C:** `MFAKey`: Migration 011 verbreitert nur die Spalte, Bestandswerte können Klartext sein, neue tragen `MFAKEYv1|`. Offene Zustellungen umfassen auch `fehlgeschlagen`. Migration 033 betrifft nur vier Tabellen. 024 betrifft vier Spalten. 008/012/013/023 enthalten Datenänderungen. 026 setzt eine leere Zustelltabelle voraus. Technische Tabelle `schema_migrations` fehlt im Bericht.
- **D:** Recovery-UI normalisiert die Passphrase vor dem KDF. Offene Punkte bleiben: AES-Schlüsselkürzung der Header-Schlüssel, RSA-OAEP-Hash, PEM-Format.

## Wesentliche Befunde für die Neuentwicklung

1. Ed25519-Signaturprüfung (v2) entfällt, solange für ein Formular kein Public Key hinterlegt ist. Neubau muss Pflicht oder Übergang entscheiden.
2. Kein Fehlversuchs-Lockout im Passwort-Login; nur Rate-Limit und Protokoll. TOTP hat Lockout (5 Versuche, 900 s).
3. Rate-Limit nicht auf Admin-Seiten und Health; keine `limit_req` in den gelesenen nginx-Dateien.
4. Nur drei Formulare haben feste Handler-UUIDs; alle anderen laufen generisch über das Feldschema.
5. Cron löscht und meldet fällige Mail-Wiederholungen, sendet aber nicht neu; manueller Resend braucht Benutzer und Passphrase.
6. Kryptoformate: `KUBUS-AEAD:1` (RSA-OAEP + AES-GCM), CBC-Altformat, `:2` mit `hpke`/`sym` (HPKE X25519/SHA-256/AES-256-GCM, `kid` aus SHA-256). Fallstricke: MFA-Secret doppelt Base64, v1-Header-Schlüssel roh, Signatur hängt an `json_encode`-Kanonisierung.
7. Testvektoren: nur der öffentliche RFC-9180-Vektor liegt als Datei vor; für alle anderen Formate müssen Fixtures aus dem Altcode erzeugt werden (ohne echte Schlüssel).
8. Migration: Tabellenliste und Risiken in C plus review-C; `migrate.php` ist nicht atomar, kennt kein Rollback; `verify.php` prüft nur eine feste Auswahl und akzeptiert leere Prüfsummen.

## Offen

- Review zu B steht aus; Korrekturen in den Teilberichten sind noch nicht eingearbeitet (die Reviews gelten als Ergänzung).
- Laufzeitretention nur teilweise geklärt; Produktivdaten, Zeilenzahlen und tatsächlich angewandte Migrationen unbekannt.
- Aus den Befunden folgende Produktentscheidungen siehe `OFFENE-ENTSCHEIDUNGEN.md` (Nr. 15 ff.).
