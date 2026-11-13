# ADR 0033: Lokale Migrationsprobe und additive Snapshot-Deltas

03.11.2026. P11-F Rest, Todolino 8B72B9D6-1FAE-4B18-AA1D-0876B1EE7D5D.
SPDX-License-Identifier: AGPL-3.0-only.

## Entscheidung und Grenzen

Ergänzt ADR 0014/0025/0030. Code englisch, Dokumentation und Nutzertexte deutsch
(gemäß ADR 0001 und explizitem Paketauftrag). Keine Cutoverfreigabe.

Die interne PWA lädt nach echtem Import eine vom Ledger des Quellnamespace
referenzierte Datenprobe (`stored_objects`, bereit, DB, :2/hpke). Auswahl aus den
höchstens ersten 1000 Objektverweisen, stabil nach Quell-ID/Slot. Ohne geeignete
Probe 404; kein fingierter Erfolg. Private alte X25519-Datenschlüssel werden nur
flüchtig als 32 Byte Base64url im Browser angenommen. RSA/CBC/:1 werden weiterhin
nicht durch P9 importiert und erhalten hier keinen Decoder.

`GET /admin/api/v1/migration/jobs/:jobId/probe` liefert Wirepaket und dessen
SHA256. Nach lokaler AEAD-Entschlüsselung und ausdrücklicher menschlicher
Bestätigung sendet `POST .../:jobId/verify` ausschließlich `{hash,success:true}`.
Der Server prüft unter Joblock, dass der Hash zur aktuellen Ledger-Probe gehört,
und speichert `probe_hash`. Erst nach dieser Quittierung erzeugt der Browser eine
frische synthetische :2/hpke-Testnachricht für denselben aus dem privaten Schlüssel
abgeleiteten Empfänger und prüft sie lokal durch Entschlüsselung. Zweites POST
mit zusätzlichem `testHash` quittiert nur den SHA256 dieses frischen Chiffrats;
ohne vorausgegangene Probenbestätigung 409. Keine Klartext-Hashes, Schlüssel,
Testpakete oder entschlüsselte Inhalte werden übertragen. Bytepuffer werden im
finally genullt; Eingabefeld nach Übernahme, Abbruch und Navigation geleert.
JavaScript-Strings/Browserkopien sind nicht garantiert physisch löschbar.

Beide Routen verwenden denselben internen Cookie-/Frische-/Live-Systemrecht-
`migration.run`-Vertrag wie die Jobsteuerung; POST zusätzlich CSRF/Origin.
Unbekannte Bodyfelder werden abgelehnt. Audit enthält nur feste Aktionscodes und
leere Details. Antworten no-store. Probe und Bestätigung werden bei laufendem
Job/Prüflauf abgelehnt. Die Bestätigung ist eine menschliche Aussage, kein
kryptographischer Beweis gegenüber dem Server und kein Berechtigungs-/Cutovertest.
Die PWA zeigt bestätigte Zustände auch nach Neuladen an.

## Delta und Idempotenz

> **Ersetzt durch [ADR 0043](0043-einmal-snapshot-quiesce.md)** (13.11.2026): Die Aktion `delta` entfällt, es gibt einen Snapshot je Quelle mit Quellen-Fingerabdruck und Schreibpause-Prüfung im Code. Der Rest dieses Abschnitts (Ledgeridentität, Nachrechnen mit dem ursprünglichen Snapshot-Hash) gilt nur noch für die Wiederholung desselben Snapshots.

`POST .../:jobId/delta` verlangt `{dumpSHA256}` eines neuen eingefrorenen Snapshots
und einen abgeschlossenen echten Import im Zustand review. Der bestehende
Quellzugang, Schema-Pin, Namespace und alle Zuordnungen bleiben erhalten. Der
neue Hash muss gültig und verschieden sein. Der Job geht erneut als **Prüflauf**
in die Warteschlange; erst das bestehende `import` startet die Übernahme.
Probe-/Testbestätigung werden beim Delta zurückgesetzt. Ein neuer Snapshot muss
vorher betrieblich unter demselben isolierten Quellzugang bereitgestellt werden;
das System restauriert keine Dumps und prüft deren Datei-Hash nicht selbst.

Ledgeridentität bleibt Namespace + Tabelle + Quell-ID + Slot. Beim Abgleich
bestehender Objekte wird der ursprüngliche Snapshot-Hash aus dem zugehörigen
`migration_runs` verwendet, um exakt den ursprünglichen Plan-/Zeilennachweis
nachzurechnen. Dadurch bleiben alte p9-1-Nachweise kompatibel: keine Neuberechnung
oder Abschwächung gespeicherter HMACs. Änderungen der Zuordnung oder bestehender
Quellzeilen bleiben Konflikte; sämtliche Zielnachweise werden weiterhin geprüft.
Nur neue Quell-IDs erzeugen Zielobjekte; Wiederholung erzeugt keine Dubletten.
Dies gilt auch bei CLI-Läufen mit neuem Dump-Hash. Sonstige Tabellen werden weiter
vollständig geprüft/importiert; keine Cursor-Abkürzung, kein blindes UPSERT.
Quelllöschungen werden weder ausgeführt noch als abgeglichen freigegeben; die
bestehende mengenbasierte Löschwarnung ist kein vollständiger Löschabgleich.
Aktive/freigegebene Formulare verhindern weiterhin den Import.

## Abbruch, Rückkehr und Abschalten

Vorhandene kooperative Pause, Dry-run-Rollback, Quellentfernung und Registry-Sperre
`migration.enabled=false` werden wiederverwendet. Pause erhält bestätigte Objekte;
Quellentfernung löscht nur Zugangssecrets und schließt den Job. Kein automatisches
Löschen importierter Daten. Vollständiger Rollback benötigt gesicherte Ziel-DB;
nach Umschaltung sind neue Einsendungen zuvor zu sichern/abzugleichen. PWA erläutert
dies und verlinkt die bestehende revisionsgeschützte Settingsverwaltung zum
Abschalten nach Quellentfernung. Kein neues Recht neben migration.run; Abschalten
bleibt `system.settings`. Kein automatisches Abschalten bei bloßer Stichprobe.

Bestandsupgrade: `backend/db/upgrades/0032-migration-verification.sql` ergänzt nur
zwei nullable Chiffrat-Hashspalten. Beide Baselineabbilder sind fortgeschrieben;
keine produktive Migration, keine gespeicherten Prüfsummen ändern. Abnahme und
Fortsetzung: [Handoff](../handoffs/P11-F-Rest.md).
