# ADR 0042: Härtung von SDK-Selbstupdate und Eingang (Review Astra 2, Rest)

12.11.2026. Status: umgesetzt (Agent, Branch `agent/astra2-reste`), Gegenlesen eingearbeitet, Lino-Entscheidung zum Reparaturpfad offen.
Todolino A5EC4A54-9669-493F-9137-8D845D1EAF9B. SPDX-License-Identifier: AGPL-3.0-only.

## Kontext

Der Codex-Review Astra 2 (`docs/paritaet/review-codex-astra-2.md`) hatte nach der ersten Runde M1, M2, M5, M6 und L1 offen:
Zwei Formulare konnten dasselbe physische Ziel bespielen, ein abgebrochener Lauf hinterließ einen unklaren Zustand, der Eingang
sammelte beliebig viele große Bodies gleichzeitig, FTP/SFTP-Sitzungen hatten keine Gesamtfrist und der Multipart-Parser las
manche Bodies anders als PHP. Ergänzt ADR 0011 (SDK-Selbstupdate).

## Entscheidung

**M1, physisches Ziel.**
- Ein Konto ist Host (klein, ohne Schlusspunkt) und Benutzername (`DeployService.accountIdentity`). Protokoll und Port zählen
  nicht, weil FTP und SFTP eines Webspace dasselbe Dateisystem sehen.
- Ein Lauf hält den Formular-Lock (`form_sdk_deploy_…`) und den Konto-Lock (`form_sdk_acct_…`, sofort oder 409 `busy`).
- `PUT …/sdk-target` hält den Formular-Lock (während eines Laufs 409) und den Zielwechsel-Lock des Kontos (`form_sdk_tchg_…`,
  bis 5 s). Erst danach startet die Transaktion. Ein Ziel darf sich mit keinem Ziel eines anderen Formulars auf demselben Konto
  überschneiden, auch nicht über einen zweiten Verbindungsdatensatz. Verglichen werden live, `.prev`, `.staging` und `.swap`,
  gleich oder als Präfix in beide Richtungen; eine Überschneidung gibt 409. Damit ist der feste Staging-Name je Ziel sicher.
- `sdk_targets.target_revision` steigt bei jedem Wechsel von Verbindung oder Pfad. Das Abschluss-UPDATE eines Laufs gilt nur
  für die Revision, mit der er begann.

**M2, Laufzustand.**
- `run_phase`, `run_action`, `run_trigger` und `run_started_at` werden vor jeder Fernänderung geschrieben; jede Phase
  (`connect`, `upload`, `swap`) vor ihrem Beginn.
- Findet ein Lauf unter dem Formular-Lock noch einen offenen Lauf, ist dessen Prozess gestorben. Er wird als `interrupted`
  in die Historie geschrieben (Historie und Zielstatus in einer Transaktion). Nur aus der Phase `swap` wird
  `last_result = repair_required` und die Versionen werden NULL; aus `connect` und `upload` bleibt das Live-Verzeichnis
  unberührt und die Versionen bleiben stehen. Der Scheduler schließt offene Läufe in jeder Runde (bei freiem Formular-Lock,
  unabhängig von `auto_update`); `GET` liefert `runPhase`.
- `PUT …/sdk-target` schließt einen offenen Lauf vorher (`DeployService.closeOpenRun`, Historie `interrupted`), statt
  `run_phase` still zu löschen.
- Wird dieselbe Version über sich selbst installiert, ist das Ergebnis `unchanged`: kein Swap, `.prev` bleibt erhalten.
- Unklare Ergebnisse (Rename ohne eindeutige Serverantwort, Frist abgelaufen) gelten als `repair_required`; nur explizite
  Serverantworten (`ftp_*`, `sftp_*`) gelten als „nicht ausgeführt“ (`swap_failed`).
- Nach Ablauf der Sitzungsfrist wird nichts mehr gesendet (FTP: `checkDeadline()` vor jedem Befehl; SFTP: Schrittzeit bis
  zur Sitzungsfrist auch für das Senden, `send` mit Timer).
- Die Automatik überspringt `repair_required`. Nur ein erfolgreicher manueller Lauf hebt den Zustand auf; ein fehlgeschlagener
  lässt ihn stehen.
- Der Deployer verweigert Installation und Rollback, wenn ein `.swap`-Rest existiert, und meldet `repair_required`, wenn das
  Zurücksetzen fehlschlägt. Versionen werden dann nicht behauptet (`installed_version`/`previous_version` NULL).

**M5, Eingang.**
- `IngestGate` begrenzt gleichzeitige Einsendungen je Replik (Standard 16) vor dem Einsammeln des Bodys: 503 `ingest_busy`
  mit `Retry-After: 1`; das SDK wiederholt 503 ohnehin.
- Der Zeitstempel der Signatur wird vor dem Parsen geprüft (403).
- Dateianzahl, Dateigröße und das Textbudget (2 MiB) gelten während des Parsens.

**M6, Fristen.** Jede FTP-/SFTP-Sitzung hat eine Gesamtfrist (`totalTimeout`, 600 s). Der Antwortrückstau ist begrenzt
(FTP 8, SFTP 4, `reply_overflow`). Es gibt höchstens 16 Vorab-Antworten je Befehl. Leere SFTP-Lesungen gelten als `no_progress`.

**L1, Parser.** Es gilt nur eine Lesart:
- Jeder Delimiter ist vollständig; Padding, Boundary-Präfixe und LF-Trenner werden abgelehnt.
- Nach dem Schluss-Delimiter folgt kein Epilog.
- Header kommen nicht doppelt vor und werden nicht gefaltet.
- Als Parameter gelten nur `name` und `filename`.
- Abgeglichen gegen PHP (`MultipartParserTests`, SDK-Kanon und `php -S`).

## Folgen

- Schema: fünf neue Spalten in `sdk_targets` (`schema-p3.sql`). Upgrade `backend/db/upgrades/0033-sdk-deploy-recovery.sql`
  (siehe unten).
- Upgrade-Kette: `MigrationRunner.upgrades` (0027, 0033) wird von `migrate` und der AdminFixture angewendet; 0033 ist mit
  `ADD COLUMN IF NOT EXISTS` idempotent. `schema-p3.sql` bleibt unverändert (Prüfsumme). Test
  `testUpgrade0033IsAppliedByMigrateAndIdempotent`.
- 4xx/503 der Deploy-Routen tragen einen eigenen Problem-Code (`sdk_deploy_busy`, `sdk_target_change_busy`,
  `sdk_target_overlap`, `sdk_<code>`, 503 `sdk_deploy_unavailable`). Die Multipart-Textgrenze (2 MiB) und die Dateigrenzen
  geben 413 `payload_too_large` (Vertrag `contracts/ingest/README.md`).
- Fehlercodes neu: `repair_required`, `interrupted`, `reply_overflow`, `deadline_exceeded`, `no_progress`, `ingest_busy`.
- Ein Ziel mit `repair_required` braucht einen manuellen Lauf. Die PWA hat keine sdk-target-Oberfläche; Verwaltung über API/MCP, PWA-Ansicht siehe Karte 503ACA52.
- `previous_version` nach einer Installation ist die Version, die der Deployer auf dem Server vorgefunden hat (nicht der
  DB-Wert); nur wenn dort keine lag, bleibt der alte Wert.

## Grenzen (offen)

- `maxConcurrent` hat keine Umgebungsvariable (fester Standard 16).
- Die Kontoerkennung kennt nur Host und Benutzer: Aliasnamen oder IPs desselben Servers gelten als verschiedene Konten.
- Kein Lasttest des Eingangs und kein streamendes Hashen (P10).
- Kein Differential gegen echten SFTP-Server im Docker und gegen Proxy/WAF.
- Upgrade 0033 ist nicht an einer Bestandsdatenbank erprobt.
- **Locks.** Die Locks (`GET_LOCK`) hängen an der DB-Verbindung. Ein Server- oder Netzausfall des Prozesses, bei dem die
  Verbindung auf dem DB-Server offen bleibt, hält den Lock bis `wait_timeout` (Standard 8 h); ein Verlust der DB-Verbindung
  gibt ihn frei, obwohl der Lauf weiterläuft. Beides ist bewusst hingenommen. `SET SESSION wait_timeout` auf Pool-Verbindungen
  wird nicht gesetzt, weil es nach der Rückgabe in den Pool weiterwirkt.
- **Reparaturpfad (offen, Frage 0DAF74B2 an Lino).** Bei `repair_required` mit `.swap`-Rest verweigert der Deployer jede
  Installation. Es gibt keinen Reparaturpfad und keinen Abgleich mit dem Server. Optionen: A) Betriebsverfahren (Admin prüft per
  FTP live/`.prev`/`.swap`, räumt von Hand auf, danach manueller Install), B) Admin-Aktion „repair“, die nur eindeutige Zustände
  herstellt, C) automatisch im Scheduler. Empfehlung: A sofort, B als Karte. Bis zur Entscheidung gilt A.
- **Slowloris.** Der Schutz vor langsamen Bodies verlangt `proxy_request_buffering on` und `client_body_timeout` im
  vorgeschalteten nginx (`deploy/proxy/nginx.conf.example`); das Backend allein schützt nicht.
- **PHP-SDK** ignoriert `Retry-After` und wertet `ingest_busy` als Endpunktausfall (Karte AF71CA8A).
