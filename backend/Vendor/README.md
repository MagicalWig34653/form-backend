# Vendor

## mysql-nio (vapor/mysql-nio 1.9.2, MIT, Lizenz in `mysql-nio/LICENSE`)

Lokal eingebunden statt als Remote-Paket (Root-`Package.swift`: `.package(path: "Vendor/mysql-nio")`; die gleiche
Identität `mysql-nio` überschreibt die transitive Abhängigkeit von mysql-kit/fluent-mysql-driver). Basis: Revision
`57fec3f24169ed65365def42e516e579a03172ee`, `Sources/` und `Package.swift` unverändert bis auf zwei markierte Patches
(`LOCAL PATCH`); das Test-Target wurde entfernt, weil `Tests/` nicht übernommen ist.

| Datei | Patch | Befund |
|---|---|---|
| `Sources/MySQLNIO/MySQLConnectionHandler.swift` (`handleHandshake`) | Ist eine `tlsConfiguration` gesetzt (= TLS verlangt) und die Begrüßung enthält kein `CLIENT_SSL`, bricht der Handshake mit `MySQLError.secureConnectionRequired` ab, bevor `SSLRequest` oder Handshake-Antwort (mit Zugangsdaten) geschrieben wird. Upstream setzte in diesem Fall im Klartext fort (`isTLS: false`). | S2-01 |
| `Sources/MySQLNIO/Packet/MySQLPacket.swift` (`description`) | Paketbeschreibung nennt nur Länge und Flags, nicht mehr die ersten 16 Payload-Bytes (enthalten bei `caching_sha2_password` über TLS das DB-Passwort). | S2-04 |

Semantik-Änderung: `tlsConfiguration != nil` heißt jetzt "TLS zwingend". Alle Aufrufer in diesem Repository
(`Persistence.configure`, Umstieg-Quellverbindung, Legacy-Befehl) übergeben bei gewolltem Klartext ausdrücklich `nil`.

Update auf eine neuere Upstream-Version: Verzeichnis ersetzen, beide `LOCAL PATCH`-Stellen erneut anwenden, Tests
`DBTLSTests` (FormPersistenceTests) müssen grün bleiben. Der Docker-Build kopiert `backend/Vendor` mit.
