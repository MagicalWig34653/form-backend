# ADR 0014: Isolierter, überprüfbarer Altimport (P9)

Stand: 03.11.2026. Implementierungsentscheidung im beauftragten Paket; keine Cutoverfreigabe.
SPDX-License-Identifier: AGPL-3.0-only.

`App migrate-legacy --plan <datei> [--dry-run] [--batch-size 100]` verwendet das neue Target `FormMigration`. Der Dump wird vorab in eine **isolierte MariaDB-Quelldatenbank** restauriert. Der Importer führt keine Dumpbefehle und keinen alten Migrationsrunner aus. Verbindlich bleiben `contracts/data/migration-mapping.md`, `abbildung.md`, `contracts/crypto/migration.md` und ADR 0006.

- Quelle: gepinnte Sitzung mit konsistentem `READ ONLY`-Snapshot, UTC. Zusätzlich ist ein ausschließlich leseberechtigter Quellaccount zu verwenden. Ziel: eigene Sitzung mit schemaspezifischer MariaDB-Sperre, aktive Formulare/Releases verhindern einen Lauf. `migrate-legacy` startet keine Scheduler/Worker.
- Unveränderlicher JSON-Plan: Quellnamespace, Dump-SHA256, explizite Kunden/Formular-/Verbindungszuordnung, optionale eindeutige Altschlüssel-Kundenzuordnung mit Generationnummer, Statistik-Prüfberichtreferenz und öffentliche Statistik-Empfängerschlüssel. Kein Kunde wird aus Namen oder Domains abgeleitet. Private Alt-Datenschlüssel werden weder benötigt noch angenommen.
- Ein Quellobjekt wird zusammen mit allen Zielzeilen, SecretStore-Schreibvorgängen und Ledger-Slots transaktional übernommen. Quell-/Zielnachweise sind HMAC-SHA256 mit separatem, dauerhaft identischem Betriebsschlüssel. Der Plan ist Teil des Quellnachweises. Zielzeilen werden beim Wiederholen vollständig nachgeprüft; Abweichungen oder fehlende Ziele sind Konflikte. Keine blinden UPSERTs auf Fachdaten.
- Zeilen werden mit Keyset-Paginierung gelesen; Commit je Quellobjekt. Wiederaufnahme scannt erneut und prüft das Ledger; der Cursor ist kein Wahrheitsnachweis. Hashaggregation erfolgt inkrementell. Ein Abbruch verliert höchstens die laufende Objekttransaktion. Fehler enthalten ausschließlich sichere Codes.
- `--dry-run` verwendet dieselben Transformationen, einschließlich SecretStore, in einer vollständig zurückgerollten Zieltransaktion mit objektweisen Savepoints. Dadurch sind Eltern innerhalb des Prüflaufs verfügbar; es bleiben weder Secrets noch Kunden, Ledger, Issues oder Runs zurück. Bei großen Beständen kann der Prüflauf entsprechend lange Transaktionen benötigen.
- Formulare/Verbindungen/Webhooks bleiben deaktiviert. Feldschema und Mail-/Domain-/Modikonfiguration werden als ausdrücklich **inaktive Legacy-Version** aufbewahrt. `inactive:migration-review` aktiviert keinen Adapter. Eine Konvertierung in aktuelle Veröffentlichungsdokumente ist ein eigener fachlicher Schritt. SMTP-Zugang und Proxy-URL/Auth werden geschützt referenziert; es erfolgen keine Netztests oder Zustellungen.
- Gültige `:2`-Pakete bleiben bytegleich. Payloadhash: dekodierte IV+Ciphertext+Tag; Wirehash getrennt. Zugeordnete öffentliche Schlüsselgeneration muss existieren. CBC/:1/defekte Pakete und offene Anhänge bleiben in der gesicherten Quelle, Einsendung im Zustand `migration-review`, mit sicherem Issue. Keine Serverentschlüsselung und kein Rewrap. Eine bereits übernommene Review-Einsendung wird später nicht still repariert/überschrieben.
- Altschlüsselgenerationen werden nur **einem** explizit zugewiesenen Kunden zugeordnet, Public Key/kid werden geprüft. Keine Vervielfältigung privater Schlüsselzugänge über Kunden. Konten, PRF-/Recovery-/Zugangshüllen sind noch nicht Teil dieses Importers; ihr Vorkommen wird als nicht abgebildeter Bestand sichtbar. (Ergänzt durch ADR 0037: Alt-Recovery-Hüllen werden bytegleich importiert; Zugang entsteht durch Übernahme im Browser.)
- Statistik erfordert eine freigegebene Bestandsprüfberichtreferenz im Plan. Alle Zusatzspalten einschließlich Domain/GCLID/UA und möglicher IP-Bezüge werden als verschlüsseltes `statistics-metadata`-Objekt erhalten. Die IP-Präsenzprüfung ist eine konservative Mustererkennung, kein Ersatz für die freigegebene Dumpprüfung. Doppelte Statistik-UUIDs deduplizieren nicht; Namespace+numerische ID bleiben die Identität.
- Idempotenz bleibt mit Rohbytes/Key-SHA256, unbekannter Umgebung/Release und `legacy-missing` gesperrt nachprüfbar. Kein Digest wird erfunden. Vorhandene Versand-/Outboxdaten lösen nie neue Effekte aus.
- Bericht: Quellinventar, Schema-HMAC, Mengen und getrennte Quell-/Ziel-HMACs je importierter Tabelle, Reviewzahlen. Diese unterschiedlichen Projektionen haben **nicht denselben Hash**; Zielparität wird gegen die beim ersten Import gespeicherten Zielnachweise geprüft. Nicht abgebildete, nicht leere Tabellen und erkannte Quelllöschungen erzeugen Issues. Rohwerte werden nicht ausgegeben.

Der Importer ist auf einen eingefrorenen, freigegebenen Snapshot ausgelegt. Andere Pläne bzw. Änderungen bestehender Quellobjekte sind Konflikte; kontrollierter finaler Delta-/Löschabgleich ist noch offen. `verified` besagt nur, dass der lokale Import ohne offene Issues durchlief. `cutoverReady` bleibt immer false; `activated` wird nie gesetzt. SDK-v2-Rollout, Berechtigungs-/Entschlüsselungsnachweise, vollständige Parität und Freigabe sind separate Voraussetzungen.

Prüfstand und konkrete Grenzen: [P9-Handoff](../handoffs/P9.md). Kein Produktivimport, kein Commit/Push.

### Korrektur der Byteprojektion (03.11.2026)

SQL-HEX ist typabhängig: numerische Werte müssen vor der Bytekodierung zu BINARY konvertiert werden. Native UUIDs werden per Spaltenmetadaten erkannt und als CHAR/utf8mb4 projiziert; echte BINARY/VARBINARY/BLOB-Spalten bleiben roh. Dieselbe Regel gilt für Quellnachweis, eingebettete Felder und Zielnachweis. NULL wird nicht zu Leerstring normalisiert. Struktur-/Dekodierungsfehler tragen sichere Tabellen-/Spaltennamen und feste Grundcodes, niemals Werte oder SQL. Sie werden nach Rollback weitergegeben; kein stiller Review-Erfolg bei beschädigter Quellprojektion. Nachweise vor dieser Korrektur werden bei Konflikt nicht automatisch umgeschrieben. Regression/Prüfstand im Handoff.

### Reviewkorrekturen: Vollständigkeit, Zusatzspalten und Wiederholung (03.11.2026)

Die erste Keyset-Seite hat keine Untergrenze; insbesondere negative IDs (Regression `ID=-2`) werden gelesen. Nach jeder Tabelle muss `sourceCount` dem Inventarzähler desselben Quellsnapshots entsprechen. Abweichungen brechen mit sicherem `countMismatch` ab und setzen den Lauf auf `failed`; ein unvollständiger Scan darf nie `verified` werden.

Die Formular-Konfigurationsprojektion besitzt eine explizite gemeinsame Spaltenliste. Nicht abgebildete Spalten mit Werten ungleich NULL/Leerstring erzeugen pro Quellzeile `unmapped-column` und zählen als Review, auch wenn die Zielobjekte bereits im Ledger stehen. Spaltenwerte gelangen weder in Issues noch in Diagnostik; automatische Übernahme unbekannter Konfiguration entfällt, weil deren Bedeutung und Schutzbedarf ungeklärt sind. Felddefinitionen werden bereits vollständig erhalten; Statistik-Zusatzspalten bleiben verschlüsselt.

Jeder abgeschlossene Import aktualisiert Status und Abschlusszeit unabhängig davon, ob sich `report_json` geändert hat. Damit kann eine erfolgreiche Wiederholung einen zuvor fehlgeschlagenen Lauf mit identischem Bericht wieder auf `verified` setzen, sofern keine offenen Issues bestehen. Fachobjekte und Ledger bleiben unverändert nachgeprüft. Prüfstand und noch ausstehende DB-Abnahme siehe P9-Handoff.

### Nachkorrektur zum Retry-Review (03.11.2026)

Der bedingungslose Abschluss-UPDATE im `LegacyImporter` bleibt maßgeblich. Der DB-Lauf `/tmp/seq3-migration.log` zeigte dennoch `failed`: Beim Abgleich von `formularFelder` erzeugte der Bytevergleich zwischen `JSONSerialization.sortedKeys` und `JSONEncoder.sortedKeys` wegen unterschiedlicher Sortierung gemischter Groß-/Kleinschreibung (z. B. `ID`) einen falschen Konflikt samt offenem `migration-review`-Issue. Feldprojektionen werden deshalb als `[String: String?]` inhaltlich verglichen; NULL, fehlende Schlüssel und geänderte Werte bleiben unterscheidbar. Offene Issues verhindern weiterhin `verified`. Der Retry-Test prüft zusätzlich den issuefreien, verifizierten Erstlauf. Keine automatische Auflösung bereits gespeicherter Issues; DB-Nachprüfung mit frischen synthetischen Testdaten ausstehend.

### Additive Snapshot-Deltas (P11-F, ADR 0033)

Die frühere Beschränkung auf denselben Snapshot-Hash wird für additive neue
Snapshots gemäß ADR 0033 ergänzt. Bestehende Quell- und Zielobjekte bleiben gegen
ihre ursprünglichen Ledgernachweise geprüft; nur neue Quell-IDs erzeugen Objekte.
Geänderte Bestandszeilen bleiben Konflikte. Live-Quelle, Löschabgleich und Cutover
werden damit weiterhin nicht freigegeben.
