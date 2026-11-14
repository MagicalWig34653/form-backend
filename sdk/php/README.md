# PHP-SDK für das Formular-Backend

Signiert Einsendungen Ihrer Webseite und sendet sie an das Backend. **Das Backend versiegelt die Daten beim Eingang** mit dem öffentlichen Schlüssel Ihres Kunden und speichert nur Chiffrat; das SDK selbst verschlüsselt nichts. Verwenden Sie daher ausschließlich HTTPS (Klartext-HTTP wird nur für `localhost` akzeptiert).

Anforderungen: PHP ≥ 8.2 mit `sodium`, `curl`, `json`, `mbstring`. Lizenz: AGPL-3.0-only.

## Zugangsdaten holen

Der Administrator des Backends erzeugt sie einmal pro Formular (siehe Admin-API, `POST /tenants/{t}/forms/{f}/sdk-credentials`). Die Antwort enthält den privaten Signaturschlüssel **nur dieses eine Mal**. Speichern Sie die Antwort als `credentials.json` **außerhalb des Web-Verzeichnisses** und beschränken Sie den Zugriff:

```sh
chmod 600 credentials.json     # das SDK verweigert Dateien, die für Gruppe/andere lesbar sind
```

## Verwenden

```php
<?php
require __DIR__ . '/vendor/autoload.php';   // oder eigenen Autoloader auf src/ (Namespace FormBackend\)

use FormBackend\Client;
use FormBackend\Credentials;
use FormBackend\Exception\RejectedException;
use FormBackend\Exception\TransportException;

$client = new Client('https://admin.example.org', Credentials::fromFile('/etc/myapp/credentials.json'));

try {
    $submission = $client->submit([
        'name'      => $_POST['name'] ?? '',
        'nachricht' => $_POST['nachricht'] ?? '',
        'interessen'=> ['a', 'b'],           // verschachtelte Felder sind erlaubt
    ]);
    echo 'Danke, Referenz: ', $submission->id;
} catch (RejectedException $e) {
    // Der Server hat abgelehnt: $e->status (403 Signatur/Zeit, 404 unbekanntes Formular, 409, 413, 429 …), $e->errorCode
} catch (TransportException $e) {
    // Keine Antwort (nach 3 Versuchen). Die Einsendung kann angekommen sein: dieselbe Anfrage mit demselben Schlüssel wiederholen.
}
```

### Besucher-IP (Missbrauchsschutz)

Das SDK sendet die Adresse des Website-Besuchers mit (`REMOTE_ADDR`), signiert mit dem Formularschlüssel und an die jeweilige Einsendung gebunden (ADR 0048). Das Backend zählt Sperre und Anfragebudget dann je Besucher statt für Ihren ganzen Webserver; ohne gültige Signatur oder mit einem älteren Backend gilt wie bisher Ihre Server-Adresse. Es werden nie `X-Forwarded-For` oder andere Header des Besuchers geglaubt, außer `REMOTE_ADDR` liegt in Ihren `trustedProxies`:

```php
$client = new Client('https://admin.example.org', $credentials,
    trustedProxies: ['10.0.0.0/8', '2001:db8:1::/48'],   // NUR die Adressen Ihres eigenen Reverse-Proxys/CDN
    forwardedHeader: 'X-Forwarded-For');                  // oder 'CF-Connecting-IP' (einzelne Adresse)
// $client = new Client(..., sendVisitorIp: false);       // Besucher-IP nicht senden
// $client = new Client(..., visitorIp: fn() => $meineAdresse); // eigene Quelle (z. B. Framework-Request)
```

`X-Forwarded-For` wird von rechts gelesen (erster nicht vertrauter Hop); ein ungültiger Eintrag ergibt die Peer-Adresse. Ohne `trustedProxies` hinter einem Reverse-Proxy sieht das SDK nur dessen Adresse (alle Besucher teilen dann einen Zähler). Datenschutz: Die Adresse wird nur als HMAC gezählt, nicht gespeichert oder protokolliert.

### Regeln für Felder

- Werte sind Zeichenketten oder ganze Zahlen, auch verschachtelt in Arrays. Wahrheitswerte, Kommazahlen und `null` wandeln Sie bewusst selbst um; sonst wirft das SDK `InvalidInputException`, **bevor** etwas gesendet wird.
- Ungültiges UTF-8, leere Namen, mehr als 1000 Werte oder Verschachtelung über 64 Ebenen werden abgelehnt.
- Oberste Feldnamen dürfen weder `.` noch Leerzeichen noch Klammern enthalten, weil PHP sie sonst stillschweigend umbenennt.
- Dateien (Multipart) werden als drittes Argument unterstützt: `submit($fields, $key, ['upload' => '/path/file.pdf'])`.

### Wiederholungen sind sicher

Jeder Aufruf trägt einen `Idempotency-Key` (zufällig, wenn Sie keinen angeben). Nur DNS-/Verbindungsfehler, Timeout, Verbindungsabbruch und HTTP 502/503/504 erlauben den nächsten Versuch. **Alle 4xx (auch 429), 500, Weiterleitungen, Zertifikatsfehler und lokale Transportfehler beenden den Aufruf.** Body einschließlich Multipart-Grenze, Idempotenzschlüssel, Zeitstempel und Signatur bleiben bytegleich. Wollen Sie selbst wiederholen, übergeben Sie denselben Schlüssel: `submit($fields, $key)`. Anderer Inhalt mit demselben Schlüssel ergibt 409.

**Wiederholungen immer mit Idempotency-Key.** Das Backend kann eine Einsendung, deren Client schon abgebrochen hat, noch zu Ende verarbeiten (Warteschlange bei Last, siehe docs/BETRIEB.md, Abschnitt Body-Budget). Nur mit demselben Schlüssel erkennt es den Wiederholungsversuch und legt keine zweite Einsendung (und keine zweite Mail) an. Das Alt-SDK des bisherigen Backends sendet keinen Schlüssel: Für Websites mit großen Uploads das neue SDK einsetzen.

### Backup-Domains und signierte Konfiguration

1. Primär- und Backup-Domain über die vorhandene API-Hostverwaltung (`GET/POST /admin/api/v1/api-hosts?tenantId=…`) anlegen, diesem Formular zuordnen und aktivieren (Bestätigung/Revision gemäß ADR 0015). Alle Hosts müssen dieselbe Releasebindung haben; überall dieselbe Backend-DB und Schlüsselkonfiguration verwenden. DNS, TLS und vertrauenswürdige Proxyheader für jeden Host einrichten.
2. Zugangsdaten mit geordneter Liste ausstellen: `POST /admin/api/v1/tenants/{t}/forms/{f}/sdk-credentials`, Body `{"endpoints":["https://api.example.org","https://backup.example.org"]}`. Dies rotiert den SDK-Signaturschlüssel wie bisher. Nur aktive, diesem Formular zugeordnete API-Hosts sind erlaubt. 1–10 eindeutige HTTPS-Ursprünge, ohne Port/Pfad/abschließenden Slash, DNS-Namen kleingeschrieben.
3. Die vollständige Antwort sicher als `credentials.json` ablegen. Sie enthält `endpoints` und `endpointSignature`. Das SDK prüft die Signatur gegen den **lokal vertrauenswürdig installierten** `signingPublicKey`. Keine Konfiguration aus Requestparametern oder ungeprüften Downloads übernehmen. Wer die gesamte Zugangsdatei ersetzen kann, kann auch Schlüssel ersetzen; die Signatur ersetzt den sicheren Ersttransfer nicht.

```php
$client = new Client(null, Credentials::fromFile('/etc/myapp/credentials.json'),
    connectTimeout: 3.0, totalBudget: 10.0, maxAttempts: 3,
    failoverTtl: 60, sessionStart: false);
```

`null` verwendet die signierte Liste. Alternativ darf exakt diese Liste als erstes Argument übergeben werden. Eine abweichende Liste/URL wird abgelehnt; unsignierte Mehrfachlisten sind verboten. Alte Zugangsdateien ohne Liste funktionieren weiterhin mit einer expliziten einzelnen URL.

Standard: maximal drei Versuche, insgesamt 10 Sekunden Netzwerkbudget je `submit`. Verbleibende Zeit wird auf verbleibende Versuche verteilt und dem Transport als vollständiges Millisekundenlimit übergeben. Bei konfiguriertem Backup begrenzt `connectTimeout` (Sekunden, Standard 3) zusätzlich den **gesamten Primärversuch**, einschließlich Verbindungsaufbau und Warten auf die Antwort. So beträgt die zusätzliche Verzögerung bei nicht erreichbarem Primärhost höchstens etwa 3 Sekunden; die Backup-Laufzeit kommt hinzu. `totalBudget` (Sekunden, Standard 10) begrenzt alle Netzwerkversuche zusammen. Das bisherige `totalTimeoutMs` bleibt kompatibel; ein explizites `totalBudget` hat Vorrang. Kleinere Restbudgets und Transportlimits gelten zusätzlich. Bei einzelnen Legacy-URLs greift die zusätzliche Primärbegrenzung nicht.

Jeder erlaubte Fehler geht einen Eintrag der aktuellen Reihenfolge weiter, am Listenende wird der letzte Host wiederholt. Keine Wartezeit zwischen Hosts. Ausnahme: antwortet ein Host mit `503` und dem Code `ingest_busy` oder `body_budget_exhausted` (Server ausgelastet, kein Ausfall), wartet das SDK die `Retry-After`-Zeit (Standard 1 s, höchstens 5 s, nie über das Zeitbudget hinaus) und wiederholt am selben Host mit demselben Schlüssel; ein Ausfallmerker wird dafür nicht gesetzt. Reicht das Restbudget nicht, kommt die `RejectedException` (`isRetryable()`, `retryAfter`) sofort. Für große Uploads `totalBudget` entsprechend anheben. **Versuchs-Timeout bei großen Bodies:** Ist der Body größer als 1 MiB (`Client::LARGE_BODY_BYTES`), hebt das SDK den Timeout jedes Versuchs auf mindestens die Wartezeit des Servers auf freies Body-Budget (`Client::SERVER_WAIT_MS`, 20 s, entspricht `BodyBudget.defaultMaxWait` des Backends) plus Übertragungszeit bei angenommenen 1 MiB/s (`Client::UPLOAD_BYTES_PER_SECOND`, bewusst konservativ; ein 10-MiB-Body bekommt also 30 s) an, höchstens aber auf das Restbudget. Grund: bricht ein Client ab, während der Server die Anfrage noch in der Warteschlange hält, kann der Server sie danach trotzdem annehmen (gemessen, siehe `docs/BETRIEB.md`, Abschnitt Body-Budget); der Wiederholungsversuch mit demselben Idempotenzschlüssel liefert dann dieselbe Einsendung, ein zu kurzer Timeout erzeugt aber unnötige Doppelversuche und verdeckt das 503. Kleine Bodies behalten die bisherige Aufteilung (Budget geteilt durch verbleibende Versuche, beim Primärhost mit Ausfallliste höchstens `connectTimeout`). Das Restbudget bleibt die Obergrenze: wer große Dateien sendet, setzt `totalBudget` (oder `totalTimeoutMs`) mindestens auf Serverwartezeit plus Übertragungszeit, sonst hilft die Anhebung nicht (Standard 10 s). Der `CurlTransport` begrenzt einen Versuch nicht mehr zusätzlich auf 20 s (`timeout: null`); ein ausdrücklich übergebener Wert gilt weiter als Obergrenze. `maxAttempts` 1–100 zählt Ausfälle und Hostwechsel; mindestens so viele Versuche wie gewünschte Hosts konfigurieren. Busy-Antworten (`ingest_busy`, `body_budget_exhausted`) verbrauchen keinen Versuch, sie sind nur durch das Zeitbudget und `Client::MAX_BUSY_ROUNDS` (100) begrenzt: für große Uploads genügt es, `totalBudget` anzuheben, `maxAttempts` muss nicht mitwachsen. Zeitbudget beginnt nach dem lokalen Bodyaufbau; eigene `Transport`-Implementierungen müssen das vierte Argument `timeoutMs` durchsetzen. Die bisherigen `sleep`-/`clock`-Parameter bleiben kompatibel, `sleep` wird nur für diese Retry-After-Pause aufgerufen (Mikrosekunden). `clock` steuert auch die Merker-Zeitstempel; `monotonicClock` dient deterministischen Budgettests.

### Kurzzeit-Merker in der Host-Session

Bei aktiver PHP-Session (`session_status() === PHP_SESSION_ACTIVE`) merkt sich das SDK einen wiederholbaren Primärausfall für `failoverTtl` Sekunden (Standard 60, positive ganze Zahl). Es speichert ausschließlich Zeitstempel und Primärindex unter `$_SESSION['kubus_form_failover'][<SHA-256 aus Formular-ID und signierter Endpunktliste>]`. Der feste Namensraum erhält keinen Request-/Nutzerinput. Formulare und unterschiedliche Listen sind getrennt. Solange der Merker gilt, lautet die Reihenfolge Backup 1, weitere Backups, Primärhost. Die signierte Liste bleibt unverändert; aus Sessionwerten entstehen niemals URLs. Auch neue Clientinstanzen derselben Host-Session nutzen den Merker.

Backup-Erfolge verlängern die TTL nicht. Nach Ablauf beginnt der nächste Aufruf automatisch wieder beim Primärhost. Ein erfolgreicher Primärversuch löscht den Merker, auch wenn er nach gescheiterten Backups erreicht wird. Permanente Fehler wie 4xx, 500 oder Zertifikatsfehler erzeugen keinen Merker.

Standardmäßig startet das SDK **keine Session**. Ohne aktive Session bleibt es zustandslos und versucht pro Aufruf den Primärhost zuerst. Optional erlaubt `sessionStart: true` einen Start, ausschließlich bei `PHP_SESSION_NONE` und `headers_sent() === false`; bei fehlgeschlagenem Start bleibt es zustandslos. Eine bereits aktive Session ist auch nach gesendeten Headern nutzbar. Das SDK schließt/committet/regeneriert keine Session, verändert keine Sessionoptionen und führt nach dem Merker-Schreiben keine Session-Lifecycle-Aktion aus. Die Host-Anwendung bestimmt weiterhin Persistierung und Lockdauer. Der Merker gilt pro Besuchersitzung; er ist kein serverweiter Ausfallcache. Keine APCu-Abhängigkeit und kein Datei-Merker oder zusätzlicher Dateisystemzugriff des SDK; bei optionalem Sessionstart greift PHP auf den von der Host-Anwendung konfigurierten Sessionhandler zu.

Die Submit-Signatur ist hostunabhängig (ADR 0020). Signiertes `_statistics` bleibt identisch. Der SDK sendet keinen Browser-Origin; Collector-CORS bleibt auf den ursprünglichen Ansichtshost begrenzt. Für Browserereignisse müssen Backups auch zur passenden Formular-/Releasebindung passen; kein Wildcard-CORS ergänzen.

### Uhr

Der Server akzeptiert Zeitstempel nur ±5 Minuten. Bei `403` zuerst prüfen, ob die Uhr Ihres Servers stimmt (NTP).

## Kommandozeile (Test und Skripte)

```sh
php bin/submit.php --credentials credentials.json --url https://admin.example.org \
    name=Beispiel 'nachricht=Hallo' 'liste[]=a' 'liste[]=b'
# Mit signierter Endpunktliste entfällt --url:
php bin/submit.php --credentials credentials.json --budget-ms 10000 --attempts 3 name=Beispiel
# gibt die Einsendungs-ID aus; Exit 0 ok, 1 abgelehnt, 2 Transportfehler, 64 Eingabefehler
```

## Sicherheitshinweise

- Der Signaturschlüssel erlaubt Einsendungen im Namen Ihres Formulars, aber kein Lesen. Bei Verdacht auf Abfluss neue Zugangsdaten erzeugen (der alte Schlüssel gilt dann noch 1 Stunde).
- Zertifikat und Hostname werden immer geprüft, Weiterleitungen nicht verfolgt, Antworten auf 64 KiB begrenzt.
- Fehlermeldungen des SDK enthalten weder Feldwerte noch Schlüsselmaterial; `var_dump`/`print_r` des `Credentials`-Objekts zeigen den Schlüssel nicht.

## Tests

```sh
php sdk/php/tests/sdk_test.php        # Einheitstests mit Fake-Transport, ohne Netzwerk
php sdk/php/tests/session_failover_test.php # Session-/TTL-/Budgetfälle mit simulierter Zeit und Session
php sdk/php/tests/curl_transport_test.php # cURL-Fehlerklassifikation und Zeitlimit ohne Sockets
# Gegen den echten Server (Swift, Datenbank): backend/integration-test.sh, Test IngestEndToEndTests/testPHPSDK…
```
