# ADR 0012 — Löschung, Löschschutz, Aufbewahrung und Chiffrat-Export

Stand 02.11.2026. Paket P8-A. Umsetzung: `FormAdmin/PrivacyRoutes.swift`, `FormAdmin/SubmissionEraser.swift`, Tests `PrivacyTests`.

## Entscheidungen

1. **`submissions.removable` ist der Löschschutz.** `1` = löschbar, `0` = gehalten (Hold). Neue Einsendungen sind löschbar (bisher stand der Eingang auf `0`; das hätte jede Aufbewahrung blockiert). Ein gehaltener Eintrag wird weder per Anfrage noch durch den Aufbewahrungsjob entfernt.
2. **Aufbewahrungsfrist je Formular ist Pflicht** (Nutzerentscheidung 13.11.2026: „Einheitlich 72 h als Voreinstellung, änderbar“; Paket EEDF6CCE). Ablage in `settings` (`scope_key = form:<uuid>`, `setting_key = retention.days`, Wert 1–3650 Tage), Standard 72 Stunden = 3 Tage (Konstante `Retention.defaultDays` in FormCore). Es gibt kein Abschalten: `PUT retention` mit `days: null`, fehlendem Feld oder Wert außerhalb 1–3650 ist 422 („Aufbewahrungsfrist ist Pflicht (1–3650 Tage).“); `GET` liefert die gespeicherte Frist, ohne Eintrag den Standard 3.
   - **Neues Formular:** `createForm` legt in derselben Transaktion `retention.days = 3` an.
   - **Eingang:** `retention_due_at = received_at + Frist` im selben Insert; fehlt die Einstellung, gilt per `COALESCE` der Standard (Absicherung, nie NULL).
   - **Freigabe:** Fehlt `retention.days`, endet `POST …/releases` mit 409 („Aufbewahrungsfrist fehlt“, Code `retention_missing`, übliches Fehlerformat); die PWA zeigt den Grund. Ohne Frist kein Live-Gang.
   - **Upgrade `0034-retention-default.sql`** (in `MigrationRunner.upgrades`, idempotent): legt für alle Formulare ohne Eintrag 3 Tage an und setzt bei Einsendungen mit `retention_due_at IS NULL` die Fälligkeit aus `received_at` (sonst jetzt) plus Formularfrist. Folge: Bestand, der älter als die Frist ist, ist sofort fällig und wird vom Job beim nächsten Lauf gelöscht (Hold und Import-Sperre ausgenommen). Das ist gewollt und gehört in die Rollout-Ankündigung.
   - **Import:** Altdaten bekommen die Frist des Zielformulars. Der Fall „formulare“ legt `retention.days = 3` per `INSERT IGNORE` an (bestehende Frist bleibt; keine Ledger-Destination, der Ledger-Vertrag bleibt unverändert), der Fall „anfragen“ setzt `retention_due_at = COALESCE(received_at, jetzt) + Formularfrist`; der Wert steht beim Schreiben fest und liegt im Ziel-Snapshot. Der Probelauf (dryRun) rollt alles zurück.
   - **Sperre während eines Imports:** Die Wiederaufnahme vergleicht Ziel-Snapshots (inkl. `retention_due_at`); geänderte oder gelöschte Zeilen ergäben `conflict` bzw. `missing_target`. Deshalb (a) lehnt `PUT retention` mit 409 (`retention_import_running`) ab, solange für das Formular ein echter Import (`migration_jobs.dry_run = 0`) in `queued`/`running`/`paused`/`failed` steht (aus `MigrationService` und `SetupMigrationRoutes` abgeleitet: Wiederaufnahme ist nur aus `paused`/`failed` möglich; `review` und `closed` setzen nicht mehr fort), und (b) überspringt der Aufbewahrungsjob Einsendungen mit `state = 'migration-review'`, solange ein solcher Job oder der Kommandozeilen-Import (`IS_USED_LOCK('form_legacy_import')`) läuft. Nach Abschluss (`review`/`closed`) greift die Frist normal. Hinweis: Bereits vor Upgrade 0034 importierte Läufe, die danach fortgesetzt werden, würden wegen der nachgetragenen Fälligkeit einen Snapshot-Konflikt melden; vor dem Upgrade abschließen.
   - Eine Änderung der Frist berechnet alle vorhandenen Fälligkeiten neu (auch gehaltener Einträge; sie bleiben durch den Hold geschützt, werden aber nach Aufhebung sofort fällig, wenn die Frist schon verstrichen ist). Die Frist ist kein Statistik-TTL (Statistik: 13 Monate, ADR 0003 Nr. 10, unberührt).
3. **Löschung ist physisch** (`SubmissionEraser`): versiegelte Objekte (inkl. Anhänge, Manifest, Checkpoints), Mail-Jobs, Ablaufzustand. Behalten werden: `deletion_records` (ohne Werte, `safe_snapshot_json = {}`), Audit, Statistikereignisse und Webhook-Outbox (ohne Inhalt), `ingest_idempotency` mit `result_state = 'deleted'` (der Schlüssel bleibt belegt, damit eine Wiederholung den Inhalt nicht wieder anlegt). Zeilen werden zuerst gesperrt (`FOR UPDATE`), danach Kinder vor Eltern gelöscht; alles in einer Transaktion je Anfrage bzw. je Einsendung (Job).
4. **Rechte:**
   - Löschen (Einzel/Stapel ≤ 100): `content.delete` auf dem Formular, frischer Login (5 min), Audit `content.delete`.
   - Hold setzen/aufheben: `content.hold` auf dem Formular, frischer Login, Audit `content.hold.set` / `content.hold.clear`.
   - Aufbewahrungsfrist ändern: `privacy.manage` auf dem **Kunden** (ein Formular-Grant genügt nicht), frischer Login. Lesen: `content.read`.
   - Export: `content.export` UND `content.read`, frischer Login, Audit `content.export`. Entschlüsseln bleibt `content.decrypt` und passiert ausschließlich im Browser.
5. **Export liefert nur Chiffrate**, seitenweise (≤ 100, Cursor wie `listEntries`), `Cache-Control: no-store`. Anhänge werden über die bestehende Anhangsroute geholt (Anzahl steht im Eintrag). Klartext-/CSV-Export ist Sache der PWA nach lokaler Entschlüsselung.
6. **Aufbewahrungsjob:** `RetentionScheduler` (stündlich, Cluster-Lock `GET_LOCK('form_retention')`, höchstens 200 Einträge je Lauf, je Eintrag eine eigene Transaktion). Löschgrund `retention`, kein Akteur.

## Grenzen / offen

- Hold ist nur ein Flag. Der Vertrag (`objektinventar.md`) sieht für den Hold einen Wechsel HPKE → sym-Wrap vor, damit gehaltene Daten Schlüsselrotation überstehen. Rotation gibt es noch nicht (offener Punkt Datenschlüssel-Rotation); dort muss Hold-Rewrap nachgezogen werden.
- Externe Speicher (S3/SFTP) kennt das Löschen noch nicht (nur `backend = 'db'` existiert).
- Kein „Betroffenenrecht“-Suchlauf (Auskunft/Löschung nach Person): die Daten sind verschlüsselt, eine Suche nach Person gäbe es nur lokal im Browser.
- Löschnachweis zählt je Einsendung (`deleted_count = 1`); kein Sammelnachweis je Stapel.
- Wiederholung nach Löschung: der Eingang antwortet mit 409 (`result_state = 'deleted'`, getestet). Wie lange der Idempotenzschlüssel danach belegt bleibt, ist nicht begrenzt (keine eigene Frist).
