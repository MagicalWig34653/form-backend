# ADR 0012 — Löschung, Löschschutz, Aufbewahrung und Chiffrat-Export

Stand 02.11.2026. Paket P8-A. Umsetzung: `FormAdmin/PrivacyRoutes.swift`, `FormAdmin/SubmissionEraser.swift`, Tests `PrivacyTests`.

## Entscheidungen

1. **`submissions.removable` ist der Löschschutz.** `1` = löschbar, `0` = gehalten (Hold). Neue Einsendungen sind löschbar (bisher stand der Eingang auf `0`; das hätte jede Aufbewahrung blockiert). Ein gehaltener Eintrag wird weder per Anfrage noch durch den Aufbewahrungsjob entfernt.
2. **Aufbewahrungsfrist je Formular** in `settings` (`scope_key = form:<uuid>`, `setting_key = retention.days`, Wert 1–3650). Ohne Eintrag keine automatische Löschung. Der Eingang setzt `retention_due_at = received_at + days` im selben Insert. Eine Änderung der Frist berechnet alle vorhandenen Fälligkeiten neu (auch gehaltener Einträge; sie bleiben durch den Hold geschützt, werden aber nach Aufhebung sofort fällig, wenn die Frist schon verstrichen ist). `days = null` schaltet ab und löscht alle Fälligkeiten. Die Frist ist kein Statistik-TTL (Statistik: 13 Monate, ADR 0003 Nr. 10, unberührt).
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
