# ADR 0048: Signierte Besucher-IP vom SDK

14.11.2026. Status: umgesetzt (Agent), Review durch Lino steht aus. Todolino 1BEEDE0F-69E1-4CAF-B1AA-35B270F368C4. SPDX-License-Identifier: AGPL-3.0-only.
Ergänzt ADR 0026 (Missbrauchsschutz) und ADR 0036 (Ingest-Budget). Anlass: Feature-Matrix 14.11., Prod-Blocker 3.

## Problem

Ruft ein Kunden-Webserver das Backend über das PHP-SDK auf, sieht das Backend nur dessen Adresse. Missbrauchssperre (`ingest_abuse_ips`), `abuse.blockedNets` und das Budget `ingest.requestsPerMinute` zählen dann alle Besucher der Website zusammen: wenige Bot-Anfragen sperren das Formular für alle.

## Altverhalten (belegt)

Das Alt-SDK schickte Besucher-IP und UA als AES-256-verschlüsselte Header `CLIENTIP-ENCRYPT`/`CLIENTUA-ENCRYPT` (`form-backend_bvk/providers/Ratelimiter.php`, `decodeClientSignals`, Schlüssel je Formular oder global). Das Backend entschlüsselte, zählte je Besucher und sperrte je Besucher. Nicht übernommen: symmetrische Verschlüsselung mit geteiltem Schlüssel und Entschlüsselung jedes Fremdwerts. Der Kern bleibt: der Webserver benennt den Besucher, der Schlüssel des Formulars beglaubigt es. Neu geschieht das mit der vorhandenen Ed25519-Request-Signatur (kein neuer geheimer Wert, keine Verschlüsselung nötig, da die Adresse im Klartext im Header zwischen SDK und Backend über HTTPS läuft und nirgends geloggt wird).

## Entscheidung

1. **Header.** `X-Kubus-Client-IP: <Adresse>` (kanonische Schreibweise: Dotted Quad, IPv4-mapped als IPv4, IPv6 komprimiert) und `X-Kubus-Client-IP-Signature: <Base64 Ed25519, 64 Byte>`.
2. **Signiert** wird mit dem Formular-Signaturschlüssel der Text `KUBUS-CLIENT-IP-V1\n<formId>\n<ip>\n<timestamp>\n<Base64-Request-Signatur>`. Die Request-Signatur deckt Methode, Pfad, Formular, Zeitstempel und Body-Hash ab. Damit ist der Anspruch an genau diese Einsendung gebunden: nicht auf einen anderen Body, ein anderes Formular oder eine andere Adresse übertragbar. Das Replay-Fenster ist das der Request-Signatur (±300 s, `RequestSignature.validTimestamp`); ein Wiederholen derselben Einsendung ist ohnehin idempotent und zählt wie jede Wiederholung ins Budget.
3. **Backend** (`SubmitHandler.resolveVisitor`): prüft den Anspruch gegen den aktuellen (und den übergangsweise gültigen vorherigen) Schlüssel des Formulars. Nur bei Erfolg gilt die Besucher-IP als Identität (`req.storage`, `VerifiedVisitorIPKey`), sonst bleibt es **stillschweigend** bei der Peer-IP (bisheriges Verhalten, kein Fehlercode, kein Orakel). Ohne Header: unverändert. Alte SDK-Versionen funktionieren ohne Änderung.
4. **Verwendung der verifizierten Besucher-IP:** Ban-Digest (`clientKey` → `visitorKey`, IPv6 je /64), `abuse.blockedNets`/UA-Muster (Roh-Besucher-IP) und `ingest.requestsPerMinute`. Besucher-IP wird nur als HMAC (`abuse-ip-v1|…`, `auth_throttles`) gespeichert, nie im Klartext, nie im Log.
5. **Obergrenze je Peer.** Neue Einstellung `ingest.peerRequestsPerMinute` (Standard 1200, 0 = aus, `FORM_INGEST_PEER_REQUESTS_PER_MINUTE`): Anfragen, die einen Besucheranspruch tragen, zählen zusätzlich je (Formular, Peer-Adresse), **vor** der Prüfung des Anspruchs (kein Schlüsselzugriff für Fluten). Anfragen ohne Anspruch (alte SDKs) sind davon nicht betroffen.
6. **SDK** (`FormBackend\VisitorIp`, `Client`-Parameter `visitorIp`, `trustedProxies`, `forwardedHeader`, `sendVisitorIp`): Standard ist `REMOTE_ADDR`. Ein Weiterleitungsheader wird nur gelesen, wenn `REMOTE_ADDR` in den konfigurierten `trustedProxies` liegt; `X-Forwarded-For` wird von rechts ausgewertet (erster nicht vertrauter Hop), jeder fehlerhafte Eintrag führt zur Peer-Adresse, nie zu einem Besucherwert. Ein anderer Header (z. B. `CF-Connecting-IP`) wird als einzelne Adresse nur von vertrauten Proxys gelesen. Die Signatur wird einmal je `submit` gebaut und bleibt bei Wiederholung/Failover bytegleich. `sendVisitorIp: false` schaltet das Senden ab.

## Warum die Peer-Obergrenze

Das Signaturgeheimnis liegt auf dem Kundenserver. Wer den Schlüssel erbeutet (oder den Webserver kompromittiert), könnte sonst bei jeder Anfrage eine neue Besucher-IP behaupten und damit sowohl Missbrauchssperre als auch Besucherbudget umgehen (jede Fantasie-IP hat ein frisches Budget). Die Obergrenze je (Formular, Peer) begrenzt das auf einen großzügigen Wert, der für reale Besuchermengen einer Website nicht greift, und bricht eine Flut, die den Anspruch immer wieder neu setzt. Sie begrenzt nur die Menge, nicht die Wirkung der Sperre auf einen fremden Besucher: ein Angreifer mit Schlüssel kann eine echte fremde Besucher-IP „vorbelasten" (Framing); das setzt aber den Schlüssel und damit schon die Möglichkeit voraus, beliebige Einsendungen zu signieren.

## Grenzen (ehrlich)

- Wer den Formularschlüssel hat, kann beliebige Besucher-IPs behaupten (Framing einzelner Besucher dieses einen Formulars, Umgehen der Besuchersperre bis zur Peer-Obergrenze). Rotation des Schlüssels (`sdk-credentials`) behebt das.
- Der Kunde entscheidet, welche Adresse er als Besucher benennt. Steht das SDK hinter einem Proxy und `trustedProxies` ist nicht gesetzt, sieht es dessen Adresse (alter Zustand: ein Zähler für alle). Ist `trustedProxies` zu weit gefasst, kann der Besucher die Adresse selbst setzen.
- Server-seitig gilt die Besucher-IP nur für Sperre/Budget, nicht für Auditdaten oder Statistik.
- Browserdirekte Einsendungen (ohne SDK) haben keinen Anspruch und zählen weiter die Peer-IP (hinter dem öffentlichen Proxy über `ClientIPResolver`).
- Der Anspruch lebt im Request-Header und ist nicht verschlüsselt (HTTPS vorausgesetzt, wie die Daten selbst).

## Vertrag und Tests

`contracts/ingest/README.md` (Header-Tabelle). Tests: `IngestDBTests` (Signatur gültig/falscher Schlüssel/andere Adresse/andere Request-Bindung/abgelaufen/Zukunft/Spoof ohne Signatur, getrennte Zählung zweier Besucher hinter einem Server, IPv6 /64, Peer-Obergrenze, Replay), PHP `sdk_test.php` (Signaturtext, Bindung, Quellen, Proxy-Regeln, Wiederholung bytegleich). Mutationsproben siehe `docs/STATUS.md`.
