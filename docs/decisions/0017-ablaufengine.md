# ADR 0017: Ablaufengine ohne Skripte

Datum: 03.11.2026. Status: Implementierungsentscheidung im beauftragten P6-Minimalkern; Laufzeit-/DB-Abnahme offen.

## Umfang und Vertrag

`FormFlow` hält den Interpreter unabhängig von HTTP und transportiert nur Effektanforderungen. Autorisierung bleibt in `FormAuth/PermissionService`, REST und spätere MCP-Aufrufer müssen dieselben Dienste verwenden. Code englisch, Dokumentation deutsch gemäß ADR 0001. Maßgeblich sind `contracts/flow/`, insbesondere `wiederanlauf.md`, und ADR 0004. Kein Editor, keine Skriptsandbox und keine Änderung am Altsystem.

Die Version 0.1.0 unterstützt einen streng validierten azyklischen Ausschnitt: entry, condition mit deklarativem Schema-Prädikat, block, wait, approval, end. Unbekannte JSON-Schlüssel, doppelte Schlüssel, Versionen, Schemafähigkeiten, Skripte, Schleifen und Teilablaufknoten werden abgewiesen. Dies ist kein allgemeiner Draft-2020-12-Validator. Die Editor-Gesamtanforderung bleibt ein späterer Ausbau.

Der feste Katalog `core@1.0.0` enthält `core.set-fields` (`config.values`), `core.rename-fields` (`config.mapping`), `core.mail` und `core.webhook` (je leere config). Stabile Referenzen samt JCS/SHA-256 werden aus `FlowDefinition.builtinReference` gebildet; Veröffentlichung bindet Block-/Modulreferenzen im Manifest. Mail benutzt den Mailplan der fixierten Formularversion und die Formularverbindung; Webhook adressiert aktive formulargebundene Endpunkte. Es gibt keine beliebigen URLs oder Empfänger aus Knotenkonfigurationen. Keine dynamisch ladbaren Plugins.

Alle bisherigen Releases besitzen einen leeren entry→end-Standardgraphen. Dieser gilt für die Ingest-Kompatibilität als „kein Ablauf“: heutiger direkter Mailversand bleibt bestehen, kein zusätzlicher Lauf/Effekt. Ein tatsächlicher Ablauf übernimmt die Zustellung vollständig; kein paralleler Legacyversand.

### Integration mit Standard-Webhooks (03.11.2026, nach main-Merge)

Die Zuständigkeit gilt für Mail **und Webhooks** anhand der unveränderlichen Definition des aufgelösten Releases: Liefert `FlowEngine.definition` den Standardplatzhalter (`nil`), reiht Ingest aktive Formular-Webhooks über `config.webhookLimits.enqueue` ein. Liefert sie einen eigenen Flow, entfällt dieses automatische Enqueue vollständig. Ausschließlich erreichte `core.webhook`-Bausteine erzeugen dann effektgebundene Outboxzeilen. Auch ein eigener Flow ohne Webhook-Baustein erzeugt keinen Standard-Webhook; Warten, Freigabe und bedingte Pfade dürfen nicht durch automatische Zustellung umgangen werden. Diese einheitliche Zuständigkeit entspricht der bereits vorhandenen Mailregel und verhindert doppelte Zustellungen sowie ungebundene, vom Flow-Abbruch nicht erfasste Aufträge. Mehrere ausdrücklich erreichte Webhook-Bausteine bleiben eigenständige Effekte.

Ein Replay erzeugt auf keinem Pfad zusätzliche Aufträge. Der Flow-Abbruch terminalisiert weiterhin nur eigene `ready`-Aufträge; keine Ausweitung auf sämtliche Aufträge einer Einsendung. Keine Schemaänderung. Nach dem Merge ist `FormWebhooks` samt Netzwerkdispatcher vorhanden; die Engine erzeugt weiterhin nur Queue-Effekte, der gemeinsame Dispatcher übernimmt deren Transport. Die Rückstaugrenze des Standard-Enqueue wird durch diese Korrektur nicht auf den bestehenden Flow-Enqueue übertragen; das bleibt eine separate Integrationslücke.

## Persistenz und Wiederanlauf

Annahme und erster Lauf einschließlich HPKE-Checkpoint unter dem öffentlichen Kundenschlüssel werden gemeinsam festgeschrieben. Daten, Outputs und Interpreterposition stehen ausschließlich im verschlüsselten Objekt. `checkpoint_json` enthält nur den Paketdigest; Requestdigests sind HMACs über den bestehenden formulargebundenen Digestdienst. Keine CEKs oder Klartexte im Ledger.

Ein Ready-Handoff hat fünf Minuten Lease; Claim ersetzt ihn atomar. Jede Änderung/Effektreservierung sperrt den Lauf und prüft Token, Fence und Ablaufzeit. Crash vor/nach Claim wird durch Wartung zu waiting-manual, niemals automatisch neu ausgeführt. Checkpoint, Timer-/Freigabegate und Revision werden atomar gespeichert. Timerablauf und Approval starten keinen Worker. Menschliches Resume verlangt aktuelle Rechte, frische DB-Sitzung, Revision, exakte gespeicherte Objektmenge und AEAD-Nachweise. Zustimmung/Ablehnung wählen den jeweiligen Graphport; frühere Approvalbesuche blockieren spätere Schritte nicht. Der Fortsetzungsbeleg wird atomar mit der neuen Lease einmalig verbraucht.

Effektidentität ist Lauf/Knoten/Besuch/Slot. Outboxeintrag und bestätigter Queue-Effekt werden in einer Transaktion geschrieben. Mail crossing-point prepared→in-flight wird vor Netzwerk-I/O festgeschrieben, erfolgreiche SMTP-Annahme bestätigt. Unbekannte Annahme bleibt uncertain und wird nicht automatisch wiederholt. SMTP kann ohne Empfängerdeduplizierung kein garantiertes Exactly-once am Empfänger liefern; garantiert wird die Ledger-/Outboxidentität und das Unterlassen blinder Wiederholung. Bestätigte Effekte werden übersprungen.

## Debug und Grenzen

Observe-Aufzeichnungen binden Release und Einsendung und enthalten ausschließlich typisierte maskierte Metadaten; kein frei übergebenes Ereignis-JSON. TTL ist 900 Sekunden ab Start und wird nie verlängert. Leseweg und Wartung löschen abgelaufene Ereignisse. Start/Lesen/Abbrechen verlangen debug.read, Mutationen Sitzung/CSRF; Zieldefinitionen test-target.manage. Aktive Testsenken, Testausführung und Korrelationsfilter bleiben ausdrücklich gesperrt, bis ein sicherer Testtransport vorhanden ist. Es gibt keinen Klartextexport.

Mailfortsetzung ohne unveränderliches vollständiges Versandmanifest bleibt gesperrt. P6 erstellt noch kein solches Manifest; initialer Versand funktioniert, nach Warten/Crash in Graphen mit Mail ist die Fortsetzung daher bewusst blockiert. Webhook-Transport siehe Integrationsregel oben.

Schritt-/Checkpointgrößen- und kumulative aktive Zeitbudgets werden teilweise geprüft (offene Durchsetzungslücken siehe Review-Nachtrag); Transportaufrufe benutzen die Grenzen des vorhandenen Maildienstes. Keine harte Prozess-/Speicherisolation, kein erzwungener Abbruch eines bereits laufenden SMTP-Aufrufs am Knotenzeitlimit. Dies und Versandmanifest/Testsenken sind Restabnahmen, keine Produktionsfreigabe.

## Review-Korrekturen 03.11.2026

Befunde 1/2/3/5/6/8: Originaleinsendungs-Resend weist Flow-Deliveries mit 409 ab, zusätzlich sperrt der gemeinsame Maildienst den Resend von `effect_id`-Zeilen. Der interne Abort-Grund erläutert das fehlende Versandmanifest; öffentlich liefert die HTTP-Middleware den festen Fehler `code=conflict`, `message=Konflikt.`. Ein `prepared`-Effekt darf mit unveränderter Effekt-/Deliveryidentität unter einer neuen gültigen Lease vorbereitet werden; erst der Crossing-Point zählt den Versandversuch. `smtp-accepted` gleicht `in-flight`/`uncertain` im Effektledger ab, auch vor Resume. Ungeklärte Zustellungen bleiben gesperrt.

Der Crossing-Point (`beginEffect`) liegt im Maildispatcher nach Queue, Secretauflösung und Transportaufbau unmittelbar vor `send`; er prüft Laufzustand, Lease, Fence und Gesamtdeadline erneut. Ein danach bereits gestarteter Transport bleibt nicht rückrufbar. Abbruch storniert atomar nur `ready`-Webhookzeilen des betreffenden Laufs. Resume-/Checkpointantworten tragen `Cache-Control: no-store`.

Wartung beendet aktive/wartende Läufe bei Gesamtdeadline als `failed`, entzieht die Lease, erhöht Fence/Revision und storniert fertige Webhookaufträge. Freigabe-Timeouts werden `expired`: `onTimeout=reject` wartet auf menschliches Resume zum rejected-Port; `onTimeout=fail` beendet den Lauf. Rechtzeitig beantwortete Freigaben bleiben auch nach Ablauf der Antwortfrist gültig. Timer-Wartezeit ist ein Resume-Gate, kein automatischer Workerstart.

Weiterhin offen (bewusst kein kleiner isolierter Fix):

- **Befund 4, Budgets:** `nodeTimeoutMs` wird nicht hart durchgesetzt, `memoryBytes` begrenzt nur serialisierten Zustand, kein Prozess-/Transportbudget; Zeit-/Größenprüfung deckt nicht alle Effekt- und Fehlerpfade ab. Erfordert ein gemeinsames Budget-/Transportkonzept und Grenz-/Absturztests. Die bisherige Beschreibung ist keine Zusage vollständiger Durchsetzung.
- **Befund 7, Sperrreihenfolge:** `SubmissionEraser.erase` sperrt zuerst Einsendung und bearbeitet danach Debug-/Effekt-/Lauf-/Objektzeilen; Checkpoint/Resume sperren zuerst den Lauf und danach Objekte/Beweise. Die gemeinsame Reihenfolge samt Fremdschlüssel-/Debugsperren und Deadlock-Retry ist noch festzulegen und mit gleichzeitigem Eraser/Checkpoint/Resume auf MariaDB zu prüfen. Ohne DB-Nebenläufigkeitsprüfung kein sicherer kleiner Fix.

Nachweise und Fortsetzung: `docs/handoffs/P6-Reviewkorrekturen.md`. Keine DB-Abnahme oder Produktionsfreigabe.
