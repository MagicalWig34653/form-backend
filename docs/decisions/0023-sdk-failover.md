# ADR 0023 – PHP-SDK-Failover über signierte Endpunktliste

Datum: 03.11.2026. Status: Umsetzung der Nutzeranforderung P7-F (Todolino D2EC6C64-AB8C-4234-A7CC-C94E80C1F89E). SPDX: AGPL-3.0-only.

## Vertrag und Begründung

Der Signaturtext aus `contracts/crypto/signatur.md` und `RequestSignature` bindet Methode, logischen Pfad, Formular, Zeitstempel und kanonischen Bodyhash, **keinen Host**. Kein neues Submit-Signaturformat nötig. Der bestehende Ingest akzeptiert alle aktiven `api_hosts`, die über `api_host_forms` zum Formular gehören; Hostauflösung bleibt auf vertrauenswürdige Proxys begrenzt. Backups sind zusätzliche Einträge derselben Verwaltung (ADR 0015), keine neue Tabelle. Sie müssen dieselbe Releasebindung, DB und Schlüssel verwenden. Unterschiedliche Releasebindungen werden bei Ausstellung verweigert; nachträgliche Änderungen müssen betrieblich koordiniert werden.

`POST …/sdk-credentials` nimmt optional `endpoints` an: geordnete eindeutige Liste von 1–10 kanonischen HTTPS-Ursprüngen (DNS kleingeschrieben, ohne Port, Pfad oder Slash). Alle müssen aktiv für dasselbe Formular zugelassen sein. Prüfung erfolgt innerhalb der bestehenden Schlüsseltransaktion unter Sperre. Bestehende Rechte/frische Anmeldung/CSRF/Audit bleiben bestehen. Antwort ergänzt Liste und `endpointSignature`, base64url ohne Padding. Signiert wird mit dem neu ausgestellten SDK-Ed25519-Schlüssel exakt:

```text
KUBUS-SDK-CONFIG-V1\n<formId lowercase>\n<endpoint1>\n<endpoint2>…
```

UTF-8, LF, kein letzter LF. Domänentrennung verhindert Verwechslung mit Submit-Signaturen. PHP verifiziert vor Verwendung gegen den aus der geschützten lokalen Zugangsdatei bekannten Public Key. Der sichere Ersttransfer der gesamten Datei bleibt Vertrauensanker; kein Netzwerk-TOFU, keine Sicherheit gegen einen Angreifer mit Schreibzugriff auf Seed/gesamte Datei. Die Server-Seeds werden weiterhin nicht gespeichert; geänderte Listen werden mit neuer Zugangsdaten-Ausgabe und Schlüsselrotation verteilt. Ein separates dauerhaftes Konfigurationssignierschlüsselsystem wäre zusätzlicher, hier nicht erforderlicher Betriebsaufwand.

Mehrfachlisten ohne Signatur sowie Überschreiben signierter Listen werden verweigert. Legacy-Datei plus einzelne explizite URL bleibt kompatibel. Keine HTTP-Weiterleitungen oder aus Antworten übernommenen Ziele. Keine APCu-/Datei-/Clientzustände zur Hostauswahl; einzige Ergänzung ist der unten beschlossene Merker in einer aktiven Host-Session.

## Versuche und Budget

Nur Netzwerkfehler (DNS, Verbindungsaufbau, Timeout, Sende-/Empfangsabbruch, leere Antwort, unvollständige Übertragung) und 502/503/504 erlauben Wiederholung. Alle 4xx einschließlich 429, alle 500 (auch leer), Redirects und sonstige Antworten stoppen. Bei bereits empfangenen 4xx-/500-Headern unterbindet auch ein späterer Übertragungsabbruch den Wechsel. Zertifikats-/Konfigurationsfehler und lokale Antwortgrößenüberschreitung stoppen. Der strengere Verzicht auch auf leere 500 vermeidet eine unzuverlässige Backend-/Proxyklassifikation.

Body und sämtliche Anwendungsheader einschließlich Idempotenzschlüssel, Multipartgrenze, Zeitstempel und Signatur entstehen einmal je Aufruf. Netzbedingt unterschiedlicher Host/TLS-Verkehr ist davon ausgenommen. Geordneter Wechsel, danach Wiederholung des letzten Hosts bis zur Versuchsgrenze. Ohne gültigen Session-Merker beginnt jeder neue Aufruf am ersten Host (Erweiterung unten). Kein Backoff; Retry-After bewirkt keine zusätzliche Wartezeit.

Standard 10.000 ms monotones Netzwerk-Gesamtbudget und drei Versuche; konfigurierbar, 1–100 Versuche. Restzeit geteilt durch verbleibende Versuche ist das vollständige nächste Transportlimit, mindestens 1 ms. cURL begrenzt zusätzlich Verbindungsaufbau und seine bisherigen eigenen Limits. Keine neuen Versuche nach Budgetende. Bodyaufbau und lokale Konfigurationsprüfung liegen außerhalb des Netzwerkbudgets. Sehr lange konfigurierte Budgets können das unveränderte ±300-s-Signaturfenster überschreiten und sind deshalb nicht sinnvoll. Eigene Transporte müssen die neue `timeoutMs`-Schnittstelle implementieren.

## Statistik, Betrieb und Abnahme

`_statistics` wird unverändert mitsigniert. Origin bleibt der Ansichtshost, nicht die jeweilige Backup-Domain. SDK ohne Origin bleibt erlaubt; Collector POST/OPTIONS verlangen weiter exakten Ansicht-Origin und passende aktive Formular-/Releaseallowlist des Zielhosts. Keine CORS-Ausweitung.

PHP-Fakes prüfen Fehlerklassen, Reihenfolge, Bytegleichheit, Budget, Versuche, Signaturmanipulation und zustandslose Folgeaufrufe. Backendregressionen prüfen Backup-Replay und signierte Ausstellung einschließlich unbekanntem Host; ohne Docker werden sie nur gebaut. Keine Schema-/Bestandsmigration. Unabhängiger Review und echte Proxy-/TLS-/DB-Abnahme vor Rollout bleiben nötig; Prüfstand im Handoff.

## Erweiterung: kurzzeitiger Session-Merker und schneller Primärversuch (03.11.2026)

Bestätigte Nutzeranforderung: APCu ist auf Kundenservern nicht voraussetzbar, ein langer Primärtimeout bei jedem Aufruf ist unzumutbar. Deshalb ausschließlich eine aktive PHP-Session nutzen; ohne aktive Session zustandslos bleiben. Keine Datei-Merker und keine neue Extension (weiter PHP 8.2+).

`Client` ergänzt `connectTimeout` (Sekunden, Standard 3), `totalBudget` (Sekunden, Standard 10), `failoverTtl` (Sekunden, Standard 60) und `sessionStart` (Standard false). Bestehendes `totalTimeoutMs` bleibt erhalten; explizites `totalBudget` überschreibt es. Bei einer signierten Liste mit Backup ist der vollständige Primärversuch auf `connectTimeout` begrenzt, damit auch ein verbundener, aber stummer Primärhost höchstens etwa 3 Sekunden zusätzlich kostet. cURL erhält dieses Limit unverändert als Obergrenze auch für den Verbindungsaufbau; kleinere Zeitanteile/Restbudgets gelten weiterhin. Das monotone Gesamtbudget umfasst alle Netzwerkversuche; Backup-Laufzeit kommt zur Primärverzögerung hinzu. Transportinterface bleibt unverändert.

Unter `$_SESSION['kubus_form_failover'][sha256(formId + LF + geordnete Endpunkte)]` liegt ausschließlich `{timestamp: int, endpoint: 0}`. Der Namensraum ist fest, der Unterschlüssel aus geprüfter lokaler Konfiguration abgeleitet; kein Request-/Nutzerinput. Wiederholbare Primär-Netzfehler und 502/503/504 setzen den Merker; terminale Fehler nicht. Nutzung und Schreiben ausschließlich bei `session_status() === PHP_SESSION_ACTIVE`. Gültigkeit: Zeitstempel nicht in der Zukunft und Alter kleiner TTL; ungültige/abgelaufene Werte werden entfernt. Gültiger Merker verschiebt ausschließlich Index 0 hinter die Backups. Sessiondaten liefern weder neue Endpunkte noch neue Listen. Backup-Erfolge verlängern den Merker nicht; nach TTL automatisch wieder Primär zuerst, Primärerfolg entfernt ihn auch vor TTL. Die Auswahl überlebt Clientinstanzen innerhalb derselben Host-Session, nicht sitzungsübergreifend.

Ohne aktive Session weder In-Memory-Ersatz noch Datei-/APCu-Merker. Das SDK startet standardmäßig keine Session, unabhängig vom Headerzustand. Nur bei `sessionStart: true`, `PHP_SESSION_NONE` und noch nicht gesendeten Headern wird einmal je Aufruf ein Start versucht; Fehlschlag fällt auf zustandslos zurück. Aktive Sessions dürfen auch nach Headerausgabe genutzt werden. Kein `session_write_close`, Commit, Regenerieren oder Ändern von Optionen/Cookies durch den Merker-Code; nach Schreiben keine Session-Lifecycle-Aktionen. Die Host-Anwendung behält Lock-/Persistierungshoheit. Optionaler Sessionstart benutzt den vorhandenen PHP-Sessionhandler; es gibt keinen eigenen Dateizugriff für den Merker.

Abnahme im vorhandenen PHP-Teststil: Fake-Transport mit virtueller Millisekundenzeit und namensräumig simuliertem Sessionstatus/Headerzustand. Geprüft: erster Ausfall 3000 ms, zweiter Aufruf direkt Backup auch über neue Clientinstanz, TTL/Rückkehr/Löschung, eigene Budgets/TTL, fehlende/deaktivierte Session, Startverbot nach Headern, erlaubter/fehlgeschlagener Opt-in-Start, terminale Fehler, verfälschte Merker und Konfigurationstrennung. Echte DNS-/TLS-/Proxyzeiten bleiben Betriebsabnahme.
