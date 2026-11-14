# Vendor

Die Kette `fluent-mysql-driver -> mysql-kit -> mysql-nio` liegt vollständig lokal vor. Root-`Package.swift` bindet nur
`Vendor/fluent-mysql-driver` ein; dessen Manifest verweist auf `../mysql-kit`, dessen Manifest auf `../mysql-nio`
(Pfadabhängigkeiten, je Identität genau eine Quelle, daher keine SwiftPM-Warnung "Conflicting identity for mysql-nio").
Jeweils nur `Sources/`, `Package.swift` und `LICENSE` (MIT) übernommen, `Tests/` und das Test-Target entfernt.
Der Docker-Build kopiert `backend/Vendor` mit; `Package.resolved` enthält diese drei Pakete nicht mehr.

| Paket | Basis | Revision |
|---|---|---|
| `mysql-nio` | vapor/mysql-nio 1.9.2 | `57fec3f24169ed65365def42e516e579a03172ee` |
| `mysql-kit` | vapor/mysql-kit 4.10.2 | `b361fb48935c7f6a4204245dd23518693d6afc37` |
| `fluent-mysql-driver` | vapor/fluent-mysql-driver 4.8.0 | `4d8f31af2a84bdbb69fbf9f4acc12cbf2f47814b` |

Alle Änderungen sind im Code mit `LOCAL PATCH` markiert (`grep -rn "LOCAL PATCH" backend/Vendor`).

| Datei | Patch | Befund |
|---|---|---|
| `mysql-nio/Sources/MySQLNIO/MySQLConnectionHandler.swift` (`handleHandshake`) | Ist eine `tlsConfiguration` gesetzt (= TLS verlangt) und die Begrüßung enthält kein `CLIENT_SSL`, bricht der Handshake mit `MySQLError.secureConnectionRequired` ab, bevor `SSLRequest` oder Handshake-Antwort (mit Zugangsdaten) geschrieben wird. Upstream setzte in diesem Fall im Klartext fort. | S2-01 |
| `mysql-nio/Sources/MySQLNIO/Packet/MySQLPacket.swift` (`description`) | Paketbeschreibung nennt nur Länge und Flags, nicht mehr die ersten 16 Payload-Bytes (bei `caching_sha2_password` über TLS das DB-Passwort). | S2-04 |
| `mysql-kit/Sources/MySQLKit/MySQLDatabase+SQL.swift` (`withSession`) | `queryLogLevel` wird an die Session weitergereicht. Upstream fiel in verschachtelten Sessions auf `.debug` zurück und loggte SQL samt Binds (Importer: Hex-Literale). | S2-04b |
| `mysql-nio/Sources/MySQLNIO/MySQLQueryCommand.swift` (`deinit`) | Weder Assertion noch Fehlerlog enthalten das SQL; nur die Statement-ID wird protokolliert, kein Trap im Debug-Build (Abbruch nach PREPARE ist ein regulärer Fall). | S2-04c |
| `mysql-nio/Sources/MySQLNIO/MySQLConnection.swift` (`connect`), `MySQLConnectionHandler.swift` (`channelInactive`), `MySQLError.swift` | Neuer Parameter `handshakeTimeout` (Standard 10 s) über Greeting, TLS und Authentifizierung (`MySQLError.handshakeTimeout`); `channelInactive` beendet das Connect-Promise während des Handshakes mit `MySQLError.closed`. Upstream ließ das Promise offen, der Poolplatz blieb belegt. | Handshake-Timeout |
| `mysql-kit/Sources/MySQLKit/MySQLConfiguration.swift`, `MySQLConnectionSource.swift` | `MySQLConfiguration.handshakeTimeout` (Standard 10 s) wird an `MySQLConnection.connect` übergeben. App-seitig nur als Testnaht: `Persistence.configure(..., handshakeTimeout:)`. | Handshake-Timeout |
| `mysql-nio/Sources/MySQLNIO/Protocol/MySQLProtocol+ERR_Packet.swift` (`redactedForConnect`), `MySQLConnectionHandler.swift` (Early-ERR, caching_sha2_password, mysql_native_password) | ERR-Pakete der Connect-Phase werden vor `MySQLError.server` auf errno und bereinigten SQLSTATE reduziert (Servertext durch festen Text ersetzt). AsyncKit loggt Pool-Connect-Fehler mit `String(reflecting:)` auf `error`, unabhängig von `sqlLogLevel`; Upstream enthielt dort DB-Benutzer, Host und beliebigen Servertext ("Access denied"). Query-Fehler bleiben unverändert. | Vendor-Review 2 (Auth-Log) |
| `mysql-kit/Package.swift`, `fluent-mysql-driver/Package.swift` | Abhängigkeit auf Geschwisterpaket per Pfad, Test-Target entfernt. | SwiftPM-Identität |

Semantik-Änderung: `tlsConfiguration != nil` heißt "TLS zwingend". Alle Aufrufer in diesem Repository (`Persistence.configure`,
Umstieg-Quellverbindung, Legacy-Befehl) übergeben bei gewolltem Klartext ausdrücklich `nil`.

Update auf eine neuere Upstream-Version: Verzeichnisse einzeln ersetzen (Manifest-Pfade auf `../<paket>` setzen, Test-Targets
entfernen), alle `LOCAL PATCH`-Stellen erneut anwenden, Revisionstabelle aktualisieren. Prüfen: `DBTLSTests`,
`DBDriverHardeningTests` (FormPersistenceTests, inkl. Auth-ERR-Log und Close-/TLS-Stall-Tests) und `MigrationTests/testImportRunInNestedSessionLogsNoStatementsOrValues`
müssen grün bleiben.
