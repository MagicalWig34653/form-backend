# P2-1 – Vertrag Eingang und Legacy

Stand 26.10.2026 · SPDX: AGPL-3.0-only. Dateibesitz: Paket P2-1,
ausschließlich `contracts/ingest/`. Maßgeblich: ADR 0001–0003,
ANFORDERUNGEN, PARITAET und die Reviews A/D. Keine Implementierung,
keine Produktionsfreigabe. OpenAPI und diese ergänzenden Byte-/Zustandsregeln
gelten gemeinsam. **VORGESCHLAGEN** ist ausdrücklich kein Beschluss; solche
Regeln dürfen erst nach Bestätigung produktiv implementiert werden.

## Geltung und Kompatibilität

Die fünf öffentlichen POST-Routen teilen Autorisierung und Fachlogik:

| Route | Parameter | Antwort |
| --- | --- | --- |
| `/endpoint/` | `f` | v1-Text |
| `/api/getFormData.php` | `z` | v1-Konfiguration als JSON; Fehler Text |
| `/api/v2/submit/` | `f` | JSON mit `submission.id` |
| `/api/v2/form/` | `f` | JSON mit `configuration` und `fields` |
| `/api/v2/key/` | `f` | JSON mit `submission.id: null` |

Direkte Skriptadressen `/endpoint/index.php`, `/api/v2/{submit,form,key}/index.php`
sind gleichwertige Aliase ohne Redirect. Der v2-Signaturpfad bleibt der
Verzeichnispfad; siehe review-A M01 und Altcode
`www/api/v2/submit/index.php:15`, `www/api/v2/form/index.php:15`,
`nginx/site-confs/default.conf:43-52`. Slashlose Varianten sind nicht zugesagt.
Andere Methoden: 405; vorgeschlagener zusätzlicher Header `Allow: POST`.
OPTIONS/CORS ist unten separat als offen behandelt.

Wire-v1 wird beibehalten, nicht sein altes Speicherkryptoformat. ADR 0001
verlangt zur Laufzeit ausschließlich `KUBUS-AEAD:2`, Standard HPKE,
optional symmetrische Zusatzhülle laut ADR 0003. Initialer Versand darf
Klartext im Arbeitsspeicher verarbeiten; kein Klartext für automatische Retries.

**Integrationsblocker:** ADR 0001 erlaubt das Lesen alter v1-Header-Schlüssel
nur im Migrationswerkzeug. Alte SDKs brauchen diese Header jedoch zur Laufzeit
(D §6.1). Dieses Paket setzt ADR 0001 nicht außer Kraft. Direkter Betrieb
unveränderter v1-SDKs ist daher noch nicht freigegeben. **VORGESCHLAGEN:**
separater Docker-Kompatibilitätsadapter (grundsätzlich ADR 0003 Nr. 6), der
das alte Wire-Protokoll terminiert und formularbezogen signiertes v2 spricht.
Vertrauensgrenze, Secretbereitstellung, autorisierte Signalweitergabe und
Zulässigkeit des alten Decoders müssen vor Umsetzung ausdrücklich geklärt
werden. Auch native v2-SDKs mit globalen Header-Schlüsseln benötigen Umstellung.
Die OpenAPI beschreibt die öffentliche Fassade, nicht einen beschlossenen
internen Adaptertransport. Keine alten Schlüssel in den neuen Kern übernehmen.

## Transport, Header und Signatur

HTTPS ist Pflicht. Submit akzeptiert Form-URL-Encoding oder Multipart;
Metadaten und Key akzeptieren Form-URL-Encoding. Kein JSON-Submit.
Verschachtelte Felder verwenden PHP-Klammernotation; SDK normalisiert boolesche
Werte zu `1`/`0`. Parser muss PHP-Array-/Listenverhalten für Signaturen erhalten;
ambige doppelte Skalare und ungültiges UTF-8 mit 400 abzulehnen ist
**VORGESCHLAGEN** und braucht Cross-SDK-Tests.

| Header | Bedeutung |
| --- | --- |
| `CLIENTUA-ENCRYPT`, `CLIENTIP-ENCRYPT` | SDK-Signale, bei key beide mit formularspezifischem Treffer zwingend |
| `X-Kubus-Timestamp` | Dezimal-Unixsekunden, Signaturzeitfenster inklusive ±300 s |
| `X-Kubus-Signature` | Standard-Base64 einer 64-Byte-Ed25519-Signatur; bei submit/form Pflicht, außer gültiger Ausnahme |
| `Idempotency-Key` | optional, nur Submit; Regeln unten |
| `CLIENTGCLID` | optionales Altsignal; keine Authentifizierung; SDK filtert `[A-Za-z0-9._-]` |
| `Origin`, `Host` | Herkunft bzw. Zielhost; keine Ersatzsignatur |
| `Forwarded`, `X-Forwarded-*`, `X-Real-IP` | ausschließlich aus explizit vertrauter Proxykette verwertbar |

SDK-Signalformat: `base64(IV[16] || HMAC-SHA256(ciphertext,key)[32] ||
ciphertext)`, AES-256-CBC mit PKCS#7. HMAC umfasst im Altprotokoll **nicht**
den IV. Nicht still ändern; eigenes neues Protokoll wäre erforderlich.
Formularschlüssel: Base64 von 32 Rohbytes; Reihenfolge aktuell, vorherig
(7 Tage). Historischer globaler Fallback: aktueller String, akzeptierte
Übergangsliste; kein Base64-Decode. Legacydecoder toleriert nichtkanonisches
Base64, prüft HMAC konstantzeitlich, liefert bei Fehler kein Signal, trimmt
Klartext. Ein fehlendes Signal ist keine pauschale Autorisierung; key verlangt
beide formularspezifischen Treffer. Altbelege:
`providers/Ratelimiter.php:53-117,237-251,300-334,408-434,740-765`,
`providers/Clients/BackendV2.php:668-702`. Globale AES-Schlüsselkürzung ist nur
statisch abgeleitet, kein verifizierter Portierungsvektor. Diese Beschreibung
ist Kompatibilitätsanforderung an eine noch zu genehmigende Legacylösung.

Signaturtext, UTF-8, LF ohne abschließenden LF:

```text
KUBUS-V2
POST
/api/v2/submit/?f=<rawurlencode(formularUUID)>
<timestamp als unveränderte Dezimalzeichenfolge>
<bodyHash als 64 kleine Hexzeichen>
```

Für form stattdessen `/api/v2/form/`. Host, Origin, Idempotency-Key und andere
Queryparameter sind im Alttext nicht gebunden. UUID nicht umschreiben.
`bodyHash = SHA256(json_encode({fields: sort(POST), files: files(FILES)},
JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR))`.
Das ist **keine** allgemeine JSON-Kanonisierung und kein Hash des HTTP-Bodys.
Assoziative Arrays rekursiv nach `ksort(SORT_STRING)`, Listen unverändert.
Leere PHP-Arrays werden `[]`, auch `fields`/`files`. Keine Whitespace-Ausgabe;
Unicode und Slash unescaped, sonst PHP-json_encode-Semantik.
Dateifelder sortiert, nur erfolgreiche Uploads; je Eintrag Reihenfolge
`name,type,error,size,sha256`, error numerisch 0, size numerisch, SHA256 über
Rohbytes. Mehrfachuploads als Liste in Originalreihenfolge, erfolglose Teile
entfallen. Uploadvalidierung erfolgt zusätzlich und darf fehlerhafte Uploads
nicht wegen des Hash-Ausschlusses akzeptieren. Belege:
`providers/AnfrageSignatur.php:131-245`,
`providers/Clients/BackendV2.php:225-262,348-390,711-728`.

ADR 0002: submit/form verlangen registrierten Public Key und gültige Signatur;
fehlend, ungültig oder abgelaufen → 403. Aktueller und zeitlich gültiger
vorheriger Public Key werden geprüft. Ausnahme je Formular muss befristet,
protokolliert und widerrufbar sein. **VORGESCHLAGEN:** nur für Altformulare ohne
Public Key; explizit durch Admin mit Grund, Beginn und absolutem UTC-Ende;
keine automatische Verlängerung, maximale Dauer 7 Tage. Ab Ende oder Widerruf
sofort 403; bei vorhandenem Key keine Umgehung fehlerhafter Signaturen.
Nach Provisionierung Ausnahme beenden. Ohne bestätigte Ausnahmedauer keine
voreingestellte Ausnahme. Das alte bedingungslose Überspringen bei fehlendem
Key entfällt (`providers/AnfrageSignatur.php:50-52,101-124`).

## Provisionierung und Rotation

Key hat eigene Authentifizierung, nicht die submit/form-Anfragesignatur;
dadurch kein Bootstrap-Zirkel. Beide Signalheader müssen formularspezifisch
verifiziert sein; globale oder gemischte Treffer → 403.
`publicKey`: kanonisches Standard-Base64 von 32 Ed25519-Public-Key-Bytes.
Private Schlüssel nie übertragen; `privateKey`, `private_key`,
`ed25519PrivateKey`, `ed25519_private_key` → 400. Sonstige unbekannte
Zusatzfelder werden wie im Altcode ignoriert.

Erstregistrierung: `provisioningTimestamp` (Dezimal, ±300 s) und
`provisioningMac` (Base64 von HMAC-SHA256, Schlüssel Rohbytes UA || IP).
MAC-Text ohne abschließenden LF:
`KUBUS-V2-KEY-PROVISIONING\nPOST\n/api/v2/key/\n<uuid>\n<timestamp>\n<publicKey>`.
Aktuelle und noch gültige vorherige Header-Schlüsselkombinationen zulässig.
201 bei Erstregistrierung, konkurrierender anderer Key → 409.

Rotation: `timestamp` (1–20 Dezimalstellen, ±300 s), `signature` (64 Byte Base64).
Text `KUBUS-V2-KEY-ROTATION\n<uuid>\n<timestamp>\n<publicKey>` wird vom bisherigen
aktuellen Key signiert. 200 bei Ersatz. Bereits aktueller Key ohne
`timestamp`/`signature` → 200; signierter Rotations-Replay wird mit noch
gültigem vorherigem Key geprüft. Vorheriger Key 7 Tage gültig; zweiter Wechsel
verdrängt ihn sofort (Altverhalten, keine zusätzliche Sperre beschlossen).
Fehlende/ungültige Autorisierung → 403, ungültige Nutzlast → 400.
Belege `www/api/v2/key/index.php:16-68`,
`providers/SignaturschluesselProvisionierung.php:21-135,160-244`,
`providers/FormularSchluessel.php:285-348`. Admin-Provisionierung und
Ausnahmeverwaltung sind nicht öffentlich und außerhalb dieses Pakets.

## Herkunft, Domains und Betriebsart

ADR 0003: Domains werden vom Administrator je Formular eingetragen, kein
DNS-Besitznachweis. Effektiven Zielhost nur vom direkten Request oder einer
explizit vertrauten, überschreibenden Proxykette bestimmen; fremde Forwarding-
Header ignorieren. Öffentlich erreichbare zentrale API-Hosts müssen ebenfalls
explizit vom Admin konfiguriert sein. Ein gültiger zentraler API-Host ist
kein Herkunftsnachweis der Kundenseite.

**VORGESCHLAGEN – Detailalgorithmus zur Bestätigung:** Hostnamen klein,
IDNA-A-Label, abschließenden DNS-Punkt entfernen, exakter Vergleich;
keine Suffix-/Wildcardfreigabe. Origins als Schema/Host/effektiver Port,
Produktion nur HTTPS; Ports und Test-HTTP explizit freigeben. Ungültiger Host
400, unbekannter/für Formular falscher Host 403. Vorhandener Origin muss exakt
auf einen eingetragenen Formular-Origin passen; `null`, Mehrfachwerte,
Userinfo oder unzulässiger Origin → 403. Host einer Kundendomain muss dasselbe
Formular auflösen wie `f`/`z`. Referer ist kein Fallback.

SDK-Server senden häufig keinen Origin. **VORGESCHLAGEN:** dann ausschließlich
über die zusätzlich geprüfte bisherige Server-IP-/CIDR-/DNS-Moduszuordnung
zulassen; keine Ableitung einer Kundendomain aus einem beliebigen Header.
Das gilt auch für Legacy und key; Schlüsselroute erfordert weiterhin ihre
beiden formularspezifischen Header. Vorhandener unzulässiger Origin wird nie
durch einen IP-Treffer geheilt. DNS-Ausfall ohne anderen positiven Treffer
→ 503, definitive Nichtübereinstimmung → 403. Direkte Browserclients ohne
Origin brauchen eine gesonderte Freigabeentscheidung.

Altcode prüft hier keine Browser-Origin-Liste: `X-Real-IP` wird gegen geordnete
`modes`-Einträge ausgewertet: erste passende IP/CIDR/aufgelöste Domain bestimmt
`production` oder `testing`, kein Treffer 403, unentscheidbares DNS 503.
Diese Fachfunktion bleibt erhalten; die Proxyvertrauensprüfung wird ergänzt.
Belege `providers/Authorization.php:183-315`,
`providers/FormularKonfiguration.php:41-65`, `providers/AnfrageIngest.php:77-92`.
Nicht mit der verschlüsselten Endnutzer-IP für Missbrauchsschutz verwechseln.
Widersprüchliche Moduszuordnungen bei neuen Konfigurationen abzulehnen ist
**VORGESCHLAGEN**; importierte Reihenfolge darf nicht still verändert werden.

Der Client darf `production`/`testing` nicht per Feld oder Header wählen.
Beide Modi validieren, scannen und verschlüsseln. Test ist kein Trockenlauf:
Altbestand nutzt Testempfänger (`providers/formulare/generisch.php:67-85`,
`providers/SendingMode.php:4-7`). **VORGESCHLAGEN:** alle Seiteneffekte im
Test ausschließlich auf verwaltete Testziele, inklusive Bestätigungsmail und
Webhook; ohne Testziel 503. Das erweitert den bisherigen Empfängerwechsel und
braucht Produktfreigabe und Abstimmung mit Ablauf-/Versandverträgen.
Keine Speicherung von IP in neuer Statistik (ADR 0003 Nr. 10).

CORS: **VORGESCHLAGEN:** standardmäßig keine Browserfreigabe; bei explizitem
Browserprofil nur exakt erlaubten Origin spiegeln, `Vary: Origin`, kein `*`,
keine Cookies. OPTIONS wäre ohne Ed25519 und ohne Seiteneffekt separat zu
begrenzen. Methoden/Header/Antwortcodes dieses Profils sind noch offen und
werden hier nicht als implementierter Endpoint behauptet.

## Idempotenz und Nebenwirkungen

Gilt für beide Submit-Routen und ihre Aliase. Scope ist Formular + getrimmter
Key, über v1/v2 hinweg; Betriebsart wird serverseitig bestimmt und darf bei
Wiederaufnahme nicht heimlich wechseln. Letzteres ist **VORGESCHLAGEN** und
muss mit Migration/DB-Vertrag koordiniert werden.
PHP-`trim` entfernt am Rand SP, HT, LF, CR, NUL und VT. Länge danach in Byte,
nicht Unicodezeichen. Fehlend, leer oder >190 Byte: ignorieren, keine Kürzung,
keine Deduplizierungszusage. Genau 190 Byte gültig. `100 × ä` = 200 UTF-8-Byte
und damit ungültig. OpenAPI `maxLength` wäre dafür falsch und wird nicht benutzt.
HTTP-Parser darf ohnehin unzulässige Steuerzeichen bereits mit 400 ablehnen.

Nach Herkunftsautorisierung und Feldvalidierung wird derselbe `bodyHash` wie
für die Signatur verglichen, vor geschäftlichen Seiteneffekten. Alle übertragenen
Felder einschließlich Bot-Token zählen. Frischer Signaturzeitstempel verändert
den Hash nicht; ein geändertes Bot-Token schon.

| Zustand | Verhalten |
| --- | --- |
| neuer gültiger Key | atomar reservieren, genau eine Anfrageidentität |
| gleiche Nutzlast, abgeschlossen | 200, ursprüngliche Identität; kein erneuter Mail-/Ablaufstart |
| abweichende Nutzlast | 409, nicht mit demselben Key wiederholen |
| gleiche Nutzlast, Bearbeitung läuft | 409, später identische Nutzlast wiederholen |
| verwaiste Bearbeitung | Lease 120 s; atomare Übernahme mit derselben Identität, nur ein Besitzer |
| paralleler Abschluss/Reservierung | erneut lesen; 200 bei Abschluss, sonst 409 |

Eine abgelaufene Lease ist keine Erlaubnis zum doppelten Versand. Zustellungen
und Outbox brauchen stabile Identität und eigene Deduplizierung; Replay darf
nur bereits vorgemerkte Webhooks aktivieren. Fehlerantwort heißt nicht, dass
keine Speicherung oder Zustellung stattgefunden hat. Ohne Key keine Zusage
gegen Doppelannahme. Client bei Netzfehlern denselben Key und dieselbe Nutzlast
verwenden, Signatur frisch erzeugen. **VORGESCHLAGEN:** Replaybindung mindestens
für die Lebensdauer der Anfrage behalten; Tombstone-/Löschregel gemäß technischem Nachtrag in ../data/abbildung.md, konkrete Fristen OFFEN;
kein unbegrenztes Exactly-once-Versprechen, separate Retention noch zu bestätigen.
Importierte Legacyreservierung ohne bodyHash besitzt keine nachträglich
beweisbare Nutzlastbindung; Migration muss sie kennzeichnen, nicht erfinden.
Altcode bestätigt solche Legacytreffer mit 200; verbindliche Übernahme dieses
Sonderfalls bleibt bis Migrationsreview **VORGESCHLAGEN**.
Belege `providers/AnfrageIngest.php:19-38,153-221,410-531,735-1000`.

## Status, Antwortformat und Reihenfolge

v1 gibt bei befüllter interner Meldung ausschließlich `<HTTP-Code> -
<englischer Statuskurztext>` zurück, sonst leeren Body. Insbesondere **nicht**
die interne Meldung oder `<UUID> - <Formularname>`: Die Aufrufer übergeben das
zwar, Response verwirft es. Korrektur zur verkürzten Darstellung in P0-A.
v2-Fehler exakt `{"error":{"code":403,"status":"Forbidden"}}`, keine
Feldwerte oder internen Diagnosen. Erfolg Submit:
`{"submission":{"id":"<uuid>"}}`; Key: dieselbe Hülle mit `id:null`.
Konfigurationsantworten sind eigene JSON-Objekte. Belege
`providers/Response.php:113-165`, `providers/FormularKonfiguration.php:68-104`.
**VORGESCHLAGEN:** v1 explizit `text/plain; charset=utf-8`, alle Antworten
`Cache-Control: no-store`, `X-Content-Type-Options: nosniff`. v2 bereits JSON UTF-8.
Kein neues Fehlerfeld oder Fehlertext als verpflichtende SDK-Abhängigkeit.

| Code | Bedeutung |
| --- | --- |
| 200 / 201 | Submit/Konfiguration/Rotation/Replay erfolgreich; 201 nur erstmaliger Key |
| 400 | unlesbare Nutzlast, Key-Nutzlast oder dort fehlendes `f` |
| 401 | fehlendes/leeres `f` bei Submit/form bzw. `z` bei v1-Konfiguration (Legacysemantik) |
| 403 | Signatur, Herkunft oder Provisionierungsautorisierung abgelehnt |
| 404 | unbekanntes Formular; Submit auch inaktiv |
| 405 | falsche Methode |
| 406 | Botprüfung negativ |
| 409 | Nutzlastkonflikt, laufende Idempotenzbearbeitung oder Key-Race |
| 412 | fehlende/ungültige Pflichtfelder oder fehlendes Bot-Token |
| 413 | Upload-, Transport- oder verschlüsselte Paketgrenze überschritten |
| 415 | Upload fehlerhaft oder Dateityp/Transporttyp unzulässig |
| 429 | Rate-Limit/Sperre |
| 451 | Malwaretreffer (Legacycode, kein rechtlicher Befund) |
| 500 | interner Verarbeitungs-/Versandfehler |
| 501 | Legacy: kein ausführbarer Handler/Feldschema (`providers/formulare/generisch.php:39-46`) |
| 503 | DNS/DB/Speicherziel nicht verfügbar; Konfiguration bei inaktivem Formular |

Statuspriorität: Transport-/Größenschutz und Rate-Limit können früh abbrechen;
v2 prüft Signatur vor dem Fachhandler. Ohne vorhandenen `f` bleibt die jeweilige
fehlender-Parameter-Antwort erhalten. Kein Idempotenztreffer darf vorher
Identität offenlegen. **VORGESCHLAGEN:** Methodenprüfung nach früher
Begrenzung, aber vor Signatur; dann Formularauflösung, Signatur, Herkunft,
technische Herkunfts-/CSRF-/Bot-/Uploadprüfung, Entfernen der Technikfelder, fachliche Normalisierung/Feldprüfung, Idempotenz und Speicher/Seiteneffekte. Diese einheitliche
405-Priorität ändert den alten v2-Fehlerpfad mit ungültiger Signatur.

## Rate-Limit und Grenzen

429 gilt auch auf Konfiguration/key und Replays; kein neuer Seiteneffekt.
**VORGESCHLAGEN:** `Retry-After` als positive ganze Sekunden auf 429, auf
409 nur bei laufender Bearbeitung (Restlease, mindestens 1), auf 503 nur bei
bekanntem Wiederholzeitpunkt. Kein Retryhinweis auf Nutzlastkonflikt/key-Race.
Fehlerhülle bleibt gleich; ohne Retryhinweis ist die 409-Ursache wireseitig
nicht unterscheidbar. Keine neuen RateLimit-Header beschlossen.

Alt-Limiter: 30 Aufrufe je IP/120 s, nach 60 kritischen Treffern 7200 s Bann;
Tor-/verdächtiger-UA-Sperre 30 Tage; requestlokal keine Doppelzählung
(`providers/Ratelimiter.php:12-36,120-187,223-235,482-514`).
**VORGESCHLAGEN:** diese Zahlen als erste Baseline; vor Bestätigung keine
neuen produktiven Grenzwerte. Mehrreplika-Grenze muss gemeinsam statt pro
Prozess zählen. Bei kaputtem Limiter 503 statt unbegrenztem Durchlassen ist
**VORGESCHLAGEN**. Vertrauenswürdige SDK-Endnutzer-IP und Transport-IP getrennt
behandeln, niemals frei gesetzte IP-Header zur Umgehung akzeptieren. Neue
Abstufungen für Metadaten/key, Sperrregeln und Lastabnahme sind offen.

Upload-Vertrag: optional ein vom Formularschema/Legacyhandler benanntes
Uploadfeld; nicht pauschal `file1` auf dem Wire. Weniger als 20.000.000 Byte
(19.999.999 zulässig; genau 20.000.000 → 413). Endung und serverseitig ermittelter
MIME müssen zusammen passen: pdf/application/pdf, png/image/png,
jpg oder jpeg/image/jpeg, heif/image/heif oder image/heif-sequence,
heic/image/heic, image/heic-sequence, image/heif oder image/heif-sequence.
Unvollständiger Upload → 415, Malware → 451. Scannerfehler wurde bisher als
`nicht_geprueft` angenommen (`providers/UploadPipeline.php:4-8,79-136`).
**BESCHLOSSEN ADR 0005 D6:** Altverhalten gilt weiter. Scannerfehler lässt durch
(kein 503, Status `nicht_geprueft`); Statuscodes 418/424 des Bewerbungshandlers
bleiben. Verschärfung unbeschlossen.
Scanstatus muss im Betrieb sichtbar sein, keine Datei als geprüft markieren.
Mehrdateifähigkeit des Signaturhashs bedeutet keine fachliche Mehrdateifreigabe.
**VORGESCHLAGEN:** zusätzliche/unbekannte Dateifelder und Mehrfachuploads mit
415 ablehnen, statt still ignorieren. Pro-Formular-Grenze gemäß ADR 0003 darf
enger sein. Obergrenzen/Mehrdateimodell sind noch zu bestätigen.

Je fertig verschlüsseltem Daten-/Anhangspaket höchstens 67.108.864 Byte
(64 MiB; Gleichheit zulässig), nicht gleich HTTP-Bodysize
(`providers/AnfrageIngest.php:38,369-403`). **VORGESCHLAGEN:** separate harte
HTTP-Bodygrenze 32 MiB = 33.554.432 Byte inklusive Multipart-Overhead; für
Metadaten/key 8192 Byte. Streamend auch ohne Content-Length begrenzen; Proxy
und Anwendung abstimmen, keine abgeschnittene Annahme. Werte müssen für
bestehende Feldschemas vor Freigabe geprüft werden. DB/S3/SFTP-Zielausfall
lehnt Annahme mit 503 ab, kein stiller Puffer (ADR 0003 Nr. 11).

Multipart: Die Summe aller Textfelder (Namen und Werte, ohne Dateien) ist auf 2 MiB = 2.097.152 Byte begrenzt;
überschritten → 413 `payload_too_large` (wie Datei- und Anzahlgrenzen, nicht 400). Die Grenze gilt während des Parsens (ADR 0042).

## Abnahme und Fortsetzung

Synthetische Beispiele liegen in `examples/`; Platzhalter sind absichtlich
keine Schlüssel/Signaturen. Keine Altanwendung, kein Testskript im Altprojekt
und keine Secrets wurden geöffnet oder ausgeführt. Altbelege relativ zu
`form-backend_bvk/`, Stand dieser statischen Lektüre; kein Laufzeitnachweis.

Vor Implementierung erforderlich: Bestätigung aller VORGESCHLAGEN-Regeln,
Auflösung ADR-0001/Legacyheader, Abstimmung Testziele/Retention/Migration;
unabhängiges Vertragsreview. P3 muss PHP→Swift-Vektoren (Unicode, Slash,
leere Arrays, verschachtelte Felder, Dateien), ±300-s-Grenze, Key-Rotation,
Ausnahmeablauf/Widerruf, 190/191-Byte-Keys, parallele Submit-/Lease-Races,
keine Doppelzustellung, Proxy-/Origin-Manipulation, Uploadgrenzen, Scanner-
und Speicherzielausfall tatsächlich prüfen. Kein solcher Integrationstest
existiert in diesem Paket.

Übergabe: Branch `main`, gemeinsamer ursprünglicher Checkout, kein Worktree
angelegt (Auftrag erlaubt Schreiben nur hier), kein Commit/Remote. Kein
laufender Job oder delegierter Agent. STATUS/ARBEITSPLAN bleiben wegen der
expliziten Schreibgrenze unverändert; Koordination muss den Stand dort
übernehmen und dieses README verlinken. Paket enthält nur Vertragsdokumente.
Prüfprotokoll steht in `validation.md`; nächster Schritt ist Review/Freigabe
der offenen Detailregeln, dann P3-Vektoren und Integrationsprüfungen.


## Technischer Nachtrag M02/M03/H01 — VORGESCHLAGEN

Vor fachlicher Normalisierung Signatur über die unveränderte kanonische
POST-/Dateidarstellung prüfen; keine Technikfelder vorher entfernen. Danach
technische Herkunfts-/CSRF-/Bot-/Uploadprüfungen mit den Originalwerten ausführen.
Anschließend `csrf_token`, `cf-turnstile-response`, `g-recaptcha-response` und
`h-captcha-response` aus der fachlichen Projektion entfernen. Erst diese
Projektion normalisieren, gesperrte Werte einsetzen und fachlich validieren;
Technikfelder weder als unbekannte Fachfelder zurückweisen noch in Nutzpakete,
Mailvorlagen, Checkpoints, Statistik, Debug oder Logs übernehmen. Die vier Namen
sind reserviert, eine gleichnamige Fachfelddefinition wird als Konflikt abgelehnt.
Auch bei leerer Fachprojektion bleibt die Persistenz ein JSON-Objekt.
Belegt: Altprojekt `providers/main.php:149–158` und
`providers/AnfrageIngest.php:332–342` (nur gelesen). Sichere Transportgrenzen,
Methoden-/Formularauflösung und frühzeitige Limits bleiben vorgeschaltet.

Idempotenzdigest bindet die unveränderte, verifizierte Anfragedarstellung gemäß
bestehendem Hashvertrag; Technikfelder bleiben dafür nur flüchtig und werden
nicht persistiert. Veränderte Captcha-/CSRF-Werte bei demselben Key können daher
einen Konflikt auslösen; keine heimliche Änderung des bestehenden Hashverfahrens.
Scopes, Release-/Modusbindung und Löschgrenzen siehe `../data/abbildung.md`.
Gemeinsame Ressourcen-ID-Typen liegen in `../flow/common.schema.json`; öffentliche
Legacy-Formularparameter werden über die explizite Importzuordnung aufgelöst,
nicht durch neues Hashen einer schon gebundenen Identität.

OFFEN bleiben fachlicher Legacyadapter, PHP-Leerwert-/Typsemantik,
unbekannte Fachfelder sowie Mehrdateipolitik (418/424 und Scannerfehler:
ADR 0005 D6 beschlossen) (übriger M02). H04/H11 und sämtliche Nutzerentscheidungen bleiben
OFFEN. Dieser technische Nachtrag bestätigt keine geänderte Legacyfehlerpriorität.


## ADR 0004 — ergänzende aktuelle Verträge

- H04: Ansichtshost eindeutig pro Formular (`domain_bindings`, UNIQUE Host),
  gemeinsame API-Hosts separat (`api_hosts/api_host_forms`); Auflösung durch das
  signierte Formular, niemals Hostdefaultkunde. Siehe ../auth/domains-proxy.md.
- ADR 0005 D1 (VORGESCHLAGEN): API-/Ingest-Hosts sind je Formular an ein Release
  koppelbar (`api_host_forms.release_id`, NULL = ungebunden). Für gebundene Hosts
  nie `forms.current_release_id`; Bindung wird erst nach Signatur-/Formular-/
  Hostfreigabeprüfung angewendet. Siehe ../auth/domains-proxy.md.
- H05: [../crypto/transport.md](../crypto/transport.md), eigene vorgeschlagene
  Wirehülle und neue OpenAPI-Routen `/api/transport/v1/{submit|form}/`.
  sym-v2 bleibt als Speicherprofil gesperrt; bestehende Signaturbytes bleiben.
- H11/M02: [legacy-adapter.md](legacy-adapter.md) legt Headeradaptergrenze,
  formularbezogene Schlüssel, vorgeschlagene Dauer und Abschaltung fest.
  Legacyvalidierung ist ein gesonderter gespeicherter Formularvertrag;
  neue Formulare typisiert. Scannerfehler-Altverhalten und 418/424 gelten (ADR 0005 D6); Statuscodes im OpenAPI-Katalog enthalten.
- H07/H09: [../flow/wiederanlauf.md](../flow/wiederanlauf.md), menschliche
  Wiederaufnahme und unveränderter Originalresend. Bearbeiten ist neuer Eingang
  mit neuer Identität und Herkunftsverweis, kein Ingest-Replay des Originals.

Die Offenliste im vorigen technischen Nachtrag beschreibt den Stand vor ADR 0004;
diese Entscheidungen und die ausdrücklich weiter offenen Detailprüfungen ersetzen sie.


## Vertragsrunde 3 — R06: Abbildung der Transporthülle auf den Digest (VORGESCHLAGEN)

Stand 28.10.2026. Es gibt **einen** Digest: `request_digest = SHA256(PHP-json_encode(
{fields, files}))` gemäß `../crypto/signatur.md`. Die Transporthülle
(`../crypto/transport.md`) ist nur ein anderer Weg, dieselbe PHP-Struktur zu
liefern; der Hüllenhash, `keyVersion`, `requestId`, `nonce` und `timestamp` sind nie
Teil des Digests. Idempotency-Key und Digest funktionieren deshalb unverändert
über beide Wege (SDK-Wechsel mit demselben Key und gleichen fachlichen Daten =
Replay, nicht 409; geänderte Daten = 409).

Eine einzige Funktion `phpEquivalentInput(transportPayload) -> (post, files)`
(und derselbe Parser für die reguläre Route) erzeugt die Struktur:

1. **fields:** JSON-String → String. JSON-Array → PHP-Liste (Schlüssel 0…n−1).
   JSON-Objekt → PHP-Array; Schlüssel, die nach PHP-Regel kanonische
   Dezimal-Ganzzahlen im int64-Bereich sind (`0`, positive ohne führende Null, auch
   negative wie `-5`; nicht `-0`, `+1`, `01`, Leerzeichen), werden Integerschlüssel,
   alle anderen bleiben Strings (korrigiert in Vertragsrunde 4, D3). Damit sind `{"0":"a","1":"b"}` und
   `["a","b"]` gleich (wie `x[0]=a&x[1]=b`). Leeres Objekt oder Array → leeres PHP-
   Array → im Digest `[]`; `fields={}` ergibt `"fields":[]`. Zahlen/bool/null im
   Transport sind nicht erlaubt (Schema). Schlüssel mit `[`, `]` oder NUL werden
   abgelehnt (Verschachtelung nur über JSON-Struktur). Das Mapping von Punkten/
   Leerzeichen in Top-Level-Namen und Tiefen-/Anzahllimits ist **identisch zur
   regulären Route** (derselbe Parser; keine zweite Regel).
2. **files:** je Eintrag `field` mit demselben Namensparser wie bei Multipart
   (`a`, `a[]`, `a[b]`, `a[b][]`). Gleiche `a[]`-Pfade bilden eine Liste in
   Reihenfolge des `files`-Arrays; dasselbe Feld ohne `[]` zweimal wird abgelehnt
   (PHP würde die erste Datei verlieren). Je Datei: `name` (nicht leer, sonst
   Ablehnung; ein leerer Name wäre in PHP `UPLOAD_ERR_NO_FILE`), `type` String,
   `error=0`, `size` = Länge der dekodierten Bytes, `sha256` über die dekodierten
   Rohbytes. Eine 0-Byte-Datei mit nicht leerem Namen ist zulässig und erscheint
   mit `size=0`. Nicht erfolgreich übertragene Teile existieren im Transport
   nicht (wie im Digest ausgelassen).
3. Danach unverändert: Dateifelder `ksort(SORT_STRING)`, Metadaten in Reihenfolge
   `name,type,error,size,sha256`, äußere Reihenfolge `fields`, `files`, PHP-Flags.
4. Größenlimits gelten vor (Hülle/Base64) und nach (Rohbytes) der Dekodierung;
   `size` ist die berechnete Rohgröße, nie ein vom Sender angegebener Wert.
5. Signatur: Die Transportroute prüft ihre eigene Hüllensignatur (`KUBUS-
   TRANSPORT-SIGN-1`); der `request_digest` wird erst nach dem Öffnen aus dem
   Innenbody berechnet und nur für Idempotenz/Replay verwendet (kein zweiter
   PHP-Signaturtext auf dieser Route).

**Kreuzvektoren (Pflicht vor Freigabe, nicht ausgeführt):** (a) leeres `fields` und
leeres `files`; (b) verschachtelte Namen und Listen vs. gleichwertiges Multipart;
(c) `docs[]` mit drei Dateien in Reihenfolge; (d) doppeltes `doc` ohne `[]`
(Ablehnung); (e) Integer-Schlüsselnormalisierung; (f) 0-Byte-Datei; (g) Unicode
und Slash; (h) Wechsel Regulär→Transport und zurück mit gleichem Idempotency-Key.
Erwartung: byte-gleicher `request_digest`; Retry bleibt Replay. Referenz:
PHP-Altcode `providers/AnfrageSignatur.php:131–245` (nur lesen).


## Vertragsrunde 4 — Befunde D1–D5 (VORGESCHLAGEN)

Stand 30.10.2026, Bezug `docs/paritaet/review-krypto-adapter.md`. Nichts ausgeführt.
Der Digest für die **Signatur** (`bodyHash`, Klartext-SHA-256) bleibt unverändert;
die folgenden Regeln betreffen Persistenz und Eingabeabbildung.

**D1 Persistierter Digest ist ein Fachdigest-HMAC.** In `ingest_idempotency` und
`workflow_runs` wird nicht der rohe `request_digest` gespeichert, sondern
`HMAC-SHA256(K_digest(form, gen), "KUBUS-DIGEST-1\n" || lowercase(formId) || "\n" || request_digest[32 Byte])`
(Spaltenname `request_digest` bleibt aus Kompatibilitätsgründen mit `backend/db/`
bestehen; Rename ist eine offene Option, kein Beschluss). `K_digest` ist ein
zufälliger 32-Byte-Serverschlüssel **pro Formular** und Generation
(`form_protocol_keys purpose='digest-hmac'`, nur `secret_ref`, nie abgeleitet aus
Kunden-/Datenschlüsseln, Signatur- oder Transportschlüsseln); die Generation steht in
`digest_key_generation`. Der Vergleich beim Replay rechnet mit dem Schlüssel der
gespeicherten Generation; ein Schlüssel wird erst entfernt, wenn keine Zeile mehr auf
ihn verweist (Retention der Aufzeichnung). Zweck: Wer nur Backup/Replika der Datenbank
liest, kann geratene Eingaben nicht offline gegen den Digest prüfen (Bestätigungsorakel).
Legacyzeilen ohne Digest (`digest_evidence='legacy-missing'`) bleiben ohne Digest und
ohne Generation. Provider des Schlüssels folgt D9 (offen). Gilt nicht für
`admin_action_idempotency` (Admin-Eingaben, nicht Formularinhalt; bewusst ausgenommen,
Bewertung offen).

**D2 Kollidierende Feldnamen werden abgelehnt.** Nach der Namensabbildung der
regulären Route (PHP: Punkt und Leerzeichen in Top-Level-Namen werden zu `_`;
Klammernotation bei Multipart/Urlencoded) darf kein Zielname zweimal entstehen:
`a.b`, `a b`, `a_b` zusammen im selben Request sind Strukturfehler → Ablehnung des
gesamten Requests ohne Nebenwirkung (gleicher Statuscode wie andere Strukturfehler im
OpenAPI-Katalog, kein neuer Code). Gilt für JSON-Objekte (Reihenfolge ist
bedeutungslos) und Multipart/Urlencoded (Wirereihenfolge ist bedeutungslos) und auf
beiden Routen; „letzter gewinnt“ wird nicht übernommen. Dasselbe gilt für Integer-
Schlüssel-Kollisionen nach Normalisierung (z. B. `"1"` und `"01"` sind verschieden und
erlaubt; zwei Namen, die auf denselben PHP-Schlüssel abbilden, nicht). Vektoren siehe unten.

**D3 Ganzzahlschlüssel.** Regel oben in Punkt 1 korrigiert. Für den Digest ist nur die
Listenerkennung relevant (Integerschlüssel genau 0…n−1 nach `ksort(SORT_STRING)`:
`ksort` vergleicht als String, `{"10":..,"2":..}` sortiert „10“ vor „2“, ist keine Liste).
Die JSON-Ausgabe der Schlüssel ist immer ein String.

**D4 Unicode im Innenbody (Transport).** Der Innenbody-Parser lehnt ab: ungültiges
UTF-8, einzelne (lone) Surrogat-Escapes `\ud800`–`\udfff` (nur gültige High+Low-Paare
sind erlaubt und werden zu einem Codepunkt), ungültige Escapes, Steuerzeichen
unescaped in Strings, doppelte Schlüssel, Schlüssel mit NUL. Kein Ersatzzeichen
U+FFFD, keine stille Veränderung. `\u0000` in **Werten**: erlaubt (Parität zur
regulären Route, die NUL in Urlencoded/Multipart-Werten akzeptiert; der Digest
schreibt `\u0000` nach PHP-`json_encode`); nachgelagerte Ziele (Mail, Export) müssen
NUL eigenständig behandeln. Alternative „NUL in Werten ablehnen“ wäre eine
Verschärfung gegenüber Altverhalten und bleibt eine Produktoption (nicht gewählt).

**D5 Signiererart und routenübergreifender Replay.** Der Idempotenz-Lookup schlüsselt
nach Formular + Key, **nicht** nach Signiererart (SDK-Wechsel Regulär↔Transport↔Adapter
mit gleichem Key und Digest ist Replay, siehe R06 oben). Antwort und Audit: Die
Antwort enthält die Identität der Erstannahme; der Audit-Eintrag des Replays
nennt die Signiererart des Replays, die Erstannahme behält ihre. Ein Replay erzeugt
nie eine Nebenwirkung oder eine Neubewertung der Erstannahme. Konsequenz akzeptiert:
Ein authentisierter Adapter-Aufruf kann eine native Erstannahme „bestätigt“ bekommen
(Informationsfluss nur an einen für dasselbe Formular authentisierten Absender).
Alternative B (Replay nur bei gleicher Signiererart, sonst 409) bräche den
SDK-Wechsel ohne Neuvergabe des Keys; nicht gewählt.

**Zusätzliche Kreuzvektoren (Pflicht vor Freigabe, nicht ausgeführt):** (i) `{"a.b":"1","a b":"2"}` und
`{"a_b":"1","a.b":"2"}` in beiden Reihenfolgen → Ablehnung, kein Digest;
(j) `{"1":"b","0":"a"}` → nach `ksort` Liste `["a","b"]`; `{"10":"x","2":"y"}` → Objekt,
Schlüsselreihenfolge „10“, „2“; `{"-5":"x"}` → Integerschlüssel, Ausgabe `"-5"`;
(k) `"\ud800"`, `"\udc00"`, `"\ud83d\ude00"` (gültig), `"\u0000"` im Wert, `"\u0000"` im Schlüssel,
`U+2028` im Wert; (l) HMAC des Digests: gleicher Digest unter zwei Formularen
und zwei Generationen ergibt vier verschiedene gespeicherte Werte; Replay mit
alter Generation vergleicht korrekt.
