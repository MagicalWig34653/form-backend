# Externe Speicher – Betriebsvertrag

Stand 03.11.2026. SPDX-License-Identifier: AGPL-3.0-only.
Maßgeblich: ADR [0019](../../docs/decisions/0019-externe-speicher.md), Objektinventar und Speicherabschnitt in SICHERHEIT-UND-DATEN.

## Gemeinsame Operationen

`ObjectStore`: `put(key,data)`, `get(key)`, `delete(key)`, `head(key) -> Bytezahl?` (async/throws). Delete bestätigt Löschung bzw. explizit bestätigte Nichtexistenz; Transport-/Rechtefehler bleiben Fehler. HEAD darf Nichtexistenz nicht aus Verbindungsfehlern ableiten. Schlüssel sind relativ, ohne leere/`.`/`..`-Segmente, Kontrollzeichen oder Backslashes, maximal 1024 UTF-8-Bytes. Paketlimit 64 MiB; Ingest begrenzt zusätzlich den HTTP-Body.

Nur `ready` und nicht abgelaufene Objekte sind lesbar. Service prüft `ciphertext_sha256` und `byte_count` für DB und extern. Backend, Verbindung und Schlüssel kommen ausschließlich aus dem mandantengebundenen Inventar.

## Upload und Wiederanlauf

Ingest persistiert `prepared` plus verschlüsselten `storage_uploads`-Puffer atomar. PUT erfolgt erst nach Commit. Bestätigung setzt `ready` und entfernt den Puffer atomar; Fehler setzt `failed`, Puffer bleibt. Wiederholung derselben Objektkennung schreibt identische Bytes. `created_at` in der Spooltabelle ist die Einreihungszeit; nach fehlgeschlagenem Versuch wird hinten neu eingereiht, damit ein dauerhaft defektes Ziel spätere Objekte nicht dauerhaft verdrängt.

Ein minütlicher, clusterweit gesperrter Job wiederholt bis zu 100 Uploads je Runde und bereinigt vorbereitete Referenzen ohne Puffer. Bereinigte Orphans bleiben `failed` im Inventar, bis eine vollständige explizite Löschung die Referenz entfernen kann. Kundengenerationen bleiben dadurch geschützt.

## Löschvertrag für interne Aufrufer

Vor Remote-I/O muss `SubmissionEraser.prepare` in einer **eigenen vorherigen SQL-Transaktion committen**. Erst danach `erase` in einer neuen Transaktion ausführen. API und Retention folgen diesem Vertrag; Wiederholungsjob findet bereits committed `deleting`-Objekte. Beide Phasen sperren die Einsendung vor Objekten; berechtigte API-Mutationen prüfen Rechte erneut in der jeweiligen Transaktion. Hold blockiert den Start; begonnene Löschung blockiert neue Holds.

`erase` prüft die gesamte eigene Objekt-/Metadatenkette und überlebende Metadatenreferenzen vor Remote-I/O. Debuglinks auf fremde Einsendungen werden nur gelöst. Fehler liefern `Outcome.pending`, behalten Inventar/Puffer und erzeugen keinen Löschbeleg. Ein API-Einzeldelete liefert HTTP 202, Batchdelete zusätzlich `pending: UUID[]`. Beleg und endgültiges Entfernen erst nach bestätigter Löschung sämtlicher externer Objekte. Auch nach SQL-Rollback bleibt die zuvor committed Löschabsicht für Wiederholung auffindbar.

## Admin-API

Basis `/admin/api/v1`. Alle folgenden Operationen verwenden vorhandene Sitzung, Budget und `system.manage`. Mutationen zusätzlich CSRF/Origin, frische Anmeldung und Audit.

| Operation | Inhalt |
| --- | --- |
| POST `/connections` | bestehende Erstellung, zusätzlich `kind=s3`; SFTP zusätzlich `config.root` |
| PUT `/tenants/{t}/connections/{c}` | bestehende kundenspezifische Freigabe |
| GET/PUT `/tenants/{t}/storage` | Kundenrichtlinie |
| GET/PUT `/tenants/{t}/forms/{f}/storage` | vollständige Formularüberschreibung; GET liefert effektive Richtlinie |
| POST `/tenants/{t}/connections/{c}/probe` | synthetische PUT/GET/HEAD/DELETE-Probe; `ok`, `cleanupConfirmed` |

Richtlinie: `{ "connectionId": "uuid" | null, "data": true | false, "attachmentThreshold": 0..67108864 | null }`. Ohne Verbindung nur DB (`data=false`, Schwelle=null). Anhänge werden erst **oberhalb** der Schwelle extern gespeichert, gemessen an ursprünglichen Bytes. Altbestände bleiben unverändert.

S3 `config`: `endpoint`, `region`, `bucket`, optional `pathStyle=true`. `credential`: JSON-String mit `accessKeyId`/`secretAccessKey`, verschlüsselt über SecretStore, bestehendes 200-Byte-Limit. HTTPS zwingend, keine Basispfade/Queries/Sessiontokens. Nur unversionierte Buckets; Antwort mit Versionskennung oder Delete-Marker wird nicht als bestätigte Löschung akzeptiert. SFTP nutzt bestehendes Passwort/Host-Key-Pinning mit absolutem `root`.
