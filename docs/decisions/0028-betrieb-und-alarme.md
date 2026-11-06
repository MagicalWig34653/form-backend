# ADR 0026: Betriebsereignisse, Chronik und Mailalarme

Status: Umsetzung des Nutzerauftrags Betrieb, 03.11.2026.

## Vertrag und Begründung

FA-085/086/089/063 sowie FA-134/135: Ein eigenes Betriebsjournal enthält ausschließlich
Formular-/Einsendungs-/Quell-/Zielkennungen, Zeitpunkt, endliche Ereignis-/Operationscodes
und Priorität 0–2. Keine frei gelieferten Fehlertexte, URLs, IPs, Mailadressen, Inhalte,
Scannerantworten oder Credentials. Technische Zielkennung bezeichnet die Mailverbindung
beziehungsweise den Webhook; tatsächliche Empfänger bleiben im verschlüsselten Manifest.

DB-Trigger erfassen Mail-/Webhook-Zustands- und Versuchszählerwechsel atomar mit der
bestehenden Verarbeitung. Scannerstatus wird nur aus einer Positivliste klassifiziert;
Speicherfehler und SDK-Ergebnisse kommen ebenfalls hinzu. Damit gehen kurze Zustände
zwischen Schedulerläufen nicht verloren und keine bestehende Fachdatei bekommt einen
zweiten Schreiber. Historische Ereignisse vor dem Upgrade werden nicht erfunden.
Noch nicht existierende DNS-/Scannerproduzenten benötigen später entsprechende Anbindung.

GET `/admin/api/v1/ops/access` liefert live erlaubte Formulare und Systemfähigkeiten.
GET `/admin/api/v1/ops?form=UUID` verlangt `audit.read` auf dem echten Formularscope
(auch ein explizites Systemgrant gilt). Keine Rollenabkürzung. Parameter: `event`,
`operation`, `from`/`to` (ISO8601, maximal 366 Tage, Standard letzte 24 h, bei aktuellen Alarmen letzter Aufbewahrungszeitraum), `submission`,
`alarms=1`, `limit` (1–100), `before` (exklusiver Journalcursor). Abfrage erfolgt vor
LIMIT vollständig im berechtigten Scope. `submission` verlangt zusätzlich `content.read`.
Absteigender Cursor mit einer zusätzlichen Zeile zeigt weitere Seiten an. Aktuelle
Alarme sind die letzte Beobachtung einer Quelle mit Priorität >0; spätere Erholung
beendet den Alarm. Die PWA zeigt Filter, Chronik und Zustellzielkennungen auf Betrieb.

POST `/admin/api/v1/ops/cleanup`: menschliche Cookie-Sitzung, CSRF/Origin, frisches
Login und `system.manage` auf Systemscope. Bereinigung und wertfreier Auditbericht
sind eine Transaktion. Höchstens 1000 Zeilen pro Datenart: Journal, abgeschlossene
Mail/Webhooks ohne Workflowbindung, abgelaufene OAuthrequests/-codes/-refreshblätter
und abgelaufene Authsperren. Keine laufenden Zustellungen oder Workflowbelege löschen.
Bei Batchgrenze erneut ausführen. Bestehende Inhalts-/Statistik-/Authwartung bleibt
zuständig für ihre Daten; alte Hit-/Blocktabellen werden nicht im neuen System erfunden.

## Alarmierung und Einstellungen

ADR 0021: Registry `ops.threshold` (1–2), `ops.intervalSeconds` (60–86400),
`ops.retentionDays` (1–365), `ops.recipient`, `ops.sender`, `ops.connection`.
ENV vor DB vor Default, live aufgelöst, bestehender Settings-Revisionsvertrag.
Ohne vollständige Mailkonfiguration keine Außenwirkung. Transport verwendet vorhandene
Mailverbindungen, verschlüsselten SecretStore und Netz-/TLS-Prüfung. Mail enthält nur
Anzahlen/Priorität und verweist auf Betrieb. Keine Formularnamen oder Einsendungsdetails.

Ein globaler DB-Lock schützt alle Instanzen, eine persistierte Schranke drosselt alle
Prioritäten zusammen. Neue passende Ereignisse während der Sperrzeit zählen als
unterdrückt; nach Ablauf wird diese Zahl auch ohne neues Ereignis berichtet.
Vor SMTP wird die Schranke gespeichert. Absturz nach Schranke oder ungewisser Versand
führt bewusst nicht zum automatischen Wiederholen derselben Alarmmail; Zustand
`claimed`/`failed` bleibt im Alarmzustand erkennbar. SMTP-Annahme ist keine Zustellgarantie.

## Schema und Abnahme

Baseline plus separat auszuführendes Upgrade `backend/db/upgrades/0026-ops.sql`;
zwei Tabellen und elf einteilige Trigger, keine DELIMITER-Sonderbehandlung.
Upgrade nur mit geprüftem Backup/DDL-Recht und unabhängiger MariaDB-Abnahme übernehmen;
Baseline-Prüfsummen bestehender Installationen nicht überschreiben. Keine Migration
oder Veröffentlichung im Rahmen dieses Pakets. Prüfstand siehe `docs/handoffs/Betrieb.md`.

Die Mailverbindung wird in `mail_deliveries.ops_connection_id` pro Versuch festgehalten;
ein späterer Zuordnungswechsel verfälscht den Abschluss dieses Versuchs nicht.

Die Alarmverarbeitung quittiert jeweils höchstens 1000 konkret gelesene Ereignisse
über `alarm_seen`. Quittierung und Zähler/Sendeschranke committen gemeinsam auf einer
fest gebundenen Verbindung. Ein globaler MAX-ID-Cursor wäre falsch: AUTO_INCREMENT-Reihenfolge
ist keine Commitreihenfolge. Später committene kleinere IDs bleiben daher ungelesen
und werden im nächsten Lauf verarbeitet. Die Alarmmail selbst folgt erst nach Commit.
