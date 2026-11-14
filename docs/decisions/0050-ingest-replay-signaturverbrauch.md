# ADR 0050: Replay einer signierten Einsendung im 300-s-Fenster (SEC-037) — Konzept

14.11.2026. Status: **Vorschlag, nicht umgesetzt** (braucht Schema-Migration, daher Koordination). Todolino 95195FD4-0E46-4888-8D87-2940479BBE8D. SPDX-License-Identifier: AGPL-3.0-only.
Betrifft `FormCrypto/Signature.swift` (`RequestSignature.text`, `validTimestamp`), `FormIngest/IngestRoutes.swift` (Schritt 3 Signatur, Schritt 5 Idempotency-Key), `contracts/ingest/README.md` (Idempotenz, Replay).

## Bewertung (belegt durch Code)

- Signaturtext = `KUBUS-V2`, Methode, Pfad, Formular, Zeitstempel, SHA-256 des kanonischen Bodys. Der `Idempotency-Key`-Header ist **nicht** signiert und optional (`effectiveIdempotencyKey`); Fenster ±300 s.
- Wer eine gültige Anfrage mitschneidet (Kopf und Body), kann sie im Fenster wiederholen: ohne Key jedes Mal als neue Einsendung (Mail, Webhook, Speicherplatz), **mit beliebig neuem Key** ebenfalls (der Key ist frei änderbar, die Signatur bleibt gültig). „Key Pflicht machen“ allein schließt das also nicht.
- Begrenzung heute: Budget je (Formular, Besucher) 60/min und Peer-Obergrenze (ADR 0048). Es entsteht keine Offenlegung und keine Änderung des Inhalts (Body ist signiert), nur Vervielfachung derselben Einsendung. Voraussetzung: Mitschnitt von Signaturheadern (TLS-Bruch, Logging beim Kunden/Proxy). Schwere: niedrig bis mittel, wie vom Board eingestuft. Kein kleiner, vertragskompatibler Fix im Code allein möglich (siehe Optionen), deshalb kein Eingriff in diesem Paket.

## Optionen

1. **Key in den Signaturtext aufnehmen.** Bricht die Wire-Kompatibilität (Alt-SDK, Legacy-API ADR 0047 und Differentialtests gegen `alt-sdk.json` rechnen mit dem festen Text); Vertragsänderung. Verworfen.
2. **Nur keylose Anfragen begrenzen** (Zähler 1 je Signatur in `auth_throttles`). Hält keinen Angreifer auf, der einen Key hinzufügt. Verworfen als Scheinlösung.
3. **Signaturverbrauch speichern (empfohlen).** Neue Tabelle `ingest_signature_uses (form_id BINARY(16), sig_hash BINARY(32), idem_key_hash BINARY(32) NULL, expires_at DATETIME(6), PRIMARY KEY (form_id, sig_hash))`. `sig_hash` = SHA-256 der 64 Signaturbytes.
   - Beim ersten Annehmen (innerhalb derselben Transaktion wie die Einsendung, nach Signaturprüfung) wird die Zeile mit dem Key-Hash (oder NULL) angelegt.
   - Gleiche Signatur, **gleicher** Key: normaler Idempotenz-Replay (unverändert 200/Replay, damit SDK-Wiederholung und Failover mit bytegleicher Signatur funktionieren).
   - Gleiche Signatur, **anderer** oder fehlender Key, oder gleiche Signatur ohne Key ein zweites Mal: `409` ohne Seiteneffekt (und ohne Auskunft, ob die Einsendung existiert).
   - `expires_at` = Zeitstempel + 300 s + Reserve; Aufräumen im bestehenden Retention-Lauf. Speicher: 2 Hashes je Einsendung für ca. 10 min.
   - Vertrag: Abschnitt Idempotenz/Replay in `contracts/ingest/README.md` ergänzen (heute VORGESCHLAGEN: „Replaybindung … behalten“). Der Satz „Ohne Key keine Zusage gegen Doppelannahme“ gilt dann nur noch für neu signierte Anfragen.
   - Randfall: zwei legitime Einsendungen derselben Sekunde mit identischem Body haben dieselbe Signatur (Ed25519 deterministisch). Das SDK sendet immer einen Key; deshalb zwei Keys, gleiche Signatur: die zweite würde 409. Gegenmaßnahme im SDK: Zeitstempel in Sekunden plus Nonce ist im festen Text nicht möglich, daher akzeptabel als Grenze (gleicher Body in derselben Sekunde = Duplikat) oder SDK wartet/erhöht den Zeitstempel um 1 s. Entscheidung offen.

## Nächste Schritte

1. Entscheidung (Lino): Option 3 und Umgang mit dem Randfall gleicher Sekunde.
2. Migration + Upgradedatei (`MigrationRunner.upgrades`), Test-first: gleiche Signatur mit neuem Key 409 ohne zweite Einsendung, gleiche Signatur gleicher Key weiter idempotent, Aufräumen. Dateibesitz: `IngestRoutes`, `Schema`, Vertrag.
