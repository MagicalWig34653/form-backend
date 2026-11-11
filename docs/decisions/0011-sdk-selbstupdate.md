# ADR 0011 – SDK-Selbstupdate per FTP/FTPS

Status: beschlossen auf Nutzerwunsch am 02.11.2026 (Umsetzungsdetails VORGESCHLAGEN). SPDX: AGPL-3.0-only.

## Anforderung

Das Backend kann das PHP-SDK auf dem Webspace eines Kunden selbst installieren und aktualisieren: Zugangsdaten und genauer Zielpfad werden hinterlegt, es gibt Rollback. **Automatische Updates sind optional** (Standard aus, je Ziel schaltbar); manuelles Installieren, Aktualisieren und Zurückrollen bleibt immer möglich.

## Entscheidungen

1. **Transport:** FTP über TLS (FTPS explizit `AUTH TLS` oder implizit, Port 990). Klartext-FTP nur mit `FORM_ALLOW_INSECURE_DEV=1`. Kontrollkanal UND Datenkanal sind verschlüsselt (`PROT P`): der hochgeladene Code wird auf dem Kundenserver ausgeführt, seine Integrität darf nicht manipulierbar sein. Passive Datenverbindung geht immer zur geprüften Adresse des Kontrollkanals (nie zur vom Server genannten, FTP-Bounce). Zieladressen laufen durch den `HostGuard` (SSRF). Server, die TLS-Sitzungswiederverwendung auf dem Datenkanal erzwingen, werden derzeit nicht unterstützt (NIOSSL), SFTP ist unter Nr. 8 umgesetzt.
2. **Quelle:** das SDK liegt im Serverabbild (`FORM_SDK_DIR`, Standard `/app/sdk`); die Version steht in `sdk/php/VERSION`, der Inhalt wird als Manifest (Pfad, Größe, SHA-256) aus den Dateien gebildet. Kein Download aus dem Internet.
3. **Installationsablauf (ohne Überschreiben im Betrieb):** Hochladen in ein Staging-Verzeichnis neben dem Zielpfad → jede Datei zurücklesen und per SHA-256 prüfen → Zielverzeichnis in `<ziel>.prev` umbenennen, Staging in `<ziel>` umbenennen → bei Fehler sofort Rückbenennung. Es bleibt genau EINE Vorversion (`.prev`). **Rollback** benennt zurück (`.prev` ⇄ aktuell). Zugangsdatei und Konfiguration des Kunden (`credentials.json` o. ä.) liegen außerhalb des SDK-Verzeichnisses und werden nie angefasst.
4. **Versionsschutz:** nur aufwärts (SemVer); Downgrade nur über den ausdrücklichen Rollback. Automatik installiert nur, wenn die Serverversion größer ist als die zuletzt installierte, und höchstens einmal je Version und Ziel (ein Fehlschlag wird nicht in Schleife wiederholt).
5. **Zugangsdaten:** in `managed_secrets` (verschlüsselt, ADR 0006 Nr. 6); `connections.kind = 'ftp'`, Host/Port/Sicherheit in `safe_config_json`. Das Ziel (Verbindung + Pfad + Auto-Flag) liegt in `sdk_targets` je Kunde und Formular; jeder Lauf in `sdk_deployments` (Verlauf, Ergebnis, Fehlercode ohne Freitext vom Server).
6. **Rechte:** neues Recht ist nicht nötig: `key.manage` am Kunden (wie SDK-Zugangsdaten), frische Anmeldung für Zielanlage/Installation/Rollback. Automatik läuft als Dienst, auf einer Replica gleichzeitig (`GET_LOCK`), Audit `service`.
7. **Nicht Teil:** Änderung der SDK-Zugangsdatei, SSH-Schlüssel-Login, Mehrere Vorversionen, Smoketest-Einsendung nach Update (Vorschlag, später).
8. **SFTP (Nutzerwunsch 02.11.2026):** zweiter Transport mit derselben Installationslogik (Protokoll `RemoteFileClient`). SFTP Version 3 über `swift-nio-ssh` (Apache-2.0), Passwort-Anmeldung, ein einziger Anmeldeversuch. **Der Host-Key ist Pflicht und wird gepinnt** (`hostKeySha256` im Format `SHA256:…` wie `ssh-keygen -l`); es gibt kein Trust-on-first-use. Der Administrator ruft den angebotenen Fingerabdruck mit `POST /connections/probe-sftp` ab, vergleicht ihn außerhalb des Systems und speichert ihn mit der Verbindung (`kind: sftp`). Abweichender Host-Key bricht sofort ab (`host_key_mismatch`). Umbenennen auf einen vorhandenen Namen schlägt fehl (kein stilles Überschreiben). Zieladressen laufen durch den `HostGuard`.
