// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import Crypto
import FormAuth
import FormCore
import FormCrypto
import FormMigration
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Source check metadata for the automatic plan (ADR 0040): keys, key ids used by submissions, form and connection
/// names. Real MariaDB source reached through the read-only path. Synthetic data only.
final class SetupMigrationKeyTests: XCTestCase {
    static let form = "11111111-1111-4111-8111-111111111111"

    struct Source {
        let name: String, reader: String, password: String
        let active: Curve25519.KeyAgreement.PrivateKey, retiring: Curve25519.KeyAgreement.PrivateKey, foreign: Curve25519.KeyAgreement.PrivateKey
        var activeKid: String { try! keyID(active.publicKey.rawRepresentation) }
        var retiringKid: String { try! keyID(retiring.publicKey.rawRepresentation) }
        var foreignKid: String { try! keyID(foreign.publicKey.rawRepresentation) }
    }

    struct D: Decodable { let d: String }
    /// Runs `body` on one pooled connection switched to the source schema and back (the pool is shared).
    func onSource<T>(_ fx: AdminFixture, _ name: String, _ body: @escaping (SQLDatabase) async throws -> T) async throws -> T {
        try await fx.sql.withSession { s in
            let original = try await s.raw("SELECT DATABASE() AS d").first(decoding: D.self)!.d
            try await s.raw("USE \(ident: name)").run()
            do { let r = try await body(s); try await s.raw("USE \(ident: original)").run(); return r }
            catch { try? await s.raw("USE \(ident: original)").run(); throw error }
        }
    }

    func withSource(_ fx: AdminFixture, _ body: (Source) async throws -> Void) async throws {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let source = Source(name: "keymap_src_" + suffix, reader: "keymap_r_" + suffix, password: "synthetic-" + suffix,
                            active: .init(), retiring: .init(), foreign: .init())
        try await fx.sql.raw("CREATE DATABASE \(ident: source.name)").run()
        do {
            for statement in ["CREATE USER '\(source.reader)'@'%' IDENTIFIED BY '\(source.password)'", "GRANT SELECT ON `\(source.name)`.* TO '\(source.reader)'@'%'"] {
                try await fx.sql.raw(SQLQueryString(statement)).run()
            }
            let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let fixture = try String(contentsOf: tests.appendingPathComponent("FormMigrationTests/Fixtures/legacy.sql"), encoding: .utf8)
            try await onSource(fx, source.name) { s in
                for statement in try SQLStatementSplitter.split(fixture) { try await s.raw(SQLQueryString(statement)).run() }
                let creator = "33333333-3333-4333-8333-333333333333"
                try await s.raw("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(bind: source.activeKid),\(bind: Blob(source.active.publicKey.rawRepresentation)),'aktiv',1700000100,\(bind: creator))").run()
                try await s.raw("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(bind: source.retiringKid),\(bind: Blob(source.foreign.publicKey.rawRepresentation)),'auslaufend',1600000000,\(bind: creator))").run()
                let a = try PackageV2.seal(Data("synthetic".utf8), recipient: source.active.publicKey.rawRepresentation).wire
                let f = try PackageV2.seal(Data("synthetic".utf8), recipient: source.foreign.publicKey.rawRepresentation).wire
                for (id, data, mail) in [(2, a, nil), (3, a, a), (4, "unsupported-synthetic-packet", f)] as [(Int, String, String?)] {
                    try await s.raw("INSERT INTO anfragen (ID,UUID,formularUUID,time,data,mailBody,removable) VALUES (\(bind: id),UUID(),\(bind: Self.form),1700000000,\(bind: data),\(bind: mail),0)").run()
                }
                try await s.raw("INSERT INTO outgoingMailServer (ID,UUID,name,SMTPHost,SMTPPassword,fromMail) VALUES (1,'44444444-4444-4444-8444-444444444444','Synthetischer Versand','smtp.example.invalid','never-in-response','test@example.invalid')").run()
                try await s.raw("UPDATE formulare SET outgoingProductionServer='44444444-4444-4444-8444-444444444444'").run()
            }
            try await body(source)
        } catch {
            try? await fx.sql.raw(SQLQueryString("DROP USER IF EXISTS '\(source.reader)'@'%'")).run()
            try? await fx.sql.raw("DROP DATABASE IF EXISTS \(ident: source.name)").run()
            throw error
        }
        try await fx.sql.raw(SQLQueryString("DROP USER IF EXISTS '\(source.reader)'@'%'")).run()
        try await fx.sql.raw("DROP DATABASE IF EXISTS \(ident: source.name)").run()
    }

    func testSourceCheckListsKeyMetadataUsageAndNamesWithoutSecrets() async throws {
        try await AdminFixture.with { fx in
            try await withSource(fx) { source in
                let secrets = try SecretStore(db: fx.app.db(.mysql), keys: StaticServerKey(Data(repeating: 31, count: 32)))
                SetupMigrationRoutes.register(fx.app, guardian: fx.guardian, secrets: secrets, allowInsecure: true, startWorker: false)
                let actor = try await fx.account(), user = try await fx.login(actor)
                try await fx.grant(actor, "migration.run", system: true, by: actor)
                let at = DB.time(Date())
                try await SystemSettings.write(fx.sql, key: "migration.enabled", value: "true", at: at)
                try await SystemSettings.write(fx.sql, key: "migration.allowedNets", value: "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16", at: at)
                let env = ProcessInfo.processInfo.environment
                let body = try String(decoding: JSONSerialization.data(withJSONObject: [
                    "host": env["P4A_DB_HOST"] ?? "127.0.0.1", "port": Int(env["P4A_DB_PORT"]!)!, "database": source.name,
                    "username": source.reader, "password": source.password, "tls": "disable"]), as: UTF8.self)
                try await user.send(.POST, "migration/test", body: body) { res in
                    XCTAssertEqual(res.status, .ok, res.body.string)
                    let text = res.body.string, json = jsonObject(res)
                    // Existing fields unchanged.
                    XCTAssertEqual(json["formIds"] as? [String], [Self.form])
                    XCTAssertNotNil(json["schemaHMAC"] as? String)
                    // Keys: metadata only, the mismatching public key is flagged, never echoed.
                    let keys = try XCTUnwrap(json["keys"] as? [[String: Any]])
                    XCTAssertEqual(Set(keys.map { $0["kid"] as? String }), [source.activeKid, source.retiringKid])
                    let active = try XCTUnwrap(keys.first { $0["kid"] as? String == source.activeKid })
                    XCTAssertEqual(active["status"] as? String, "aktiv")
                    XCTAssertEqual(active["createdAt"] as? Int, 1700000100)
                    XCTAssertEqual(active["publicKeyValid"] as? Bool, true)
                    let retiring = try XCTUnwrap(keys.first { $0["kid"] as? String == source.retiringKid })
                    XCTAssertEqual(retiring["status"] as? String, "auslaufend")
                    XCTAssertEqual(retiring["publicKeyValid"] as? Bool, false)
                    XCTAssertEqual(Set(keys.flatMap { $0.keys }), ["kid", "status", "createdAt", "publicKeyValid"])
                    XCTAssertEqual(json["keysComplete"] as? Bool, true)
                    // Usage: one count per submission and kid; the foreign kid is not in the key store.
                    let usage = try XCTUnwrap(json["keyUsage"] as? [String: Any])
                    XCTAssertEqual(usage["complete"] as? Bool, true)
                    XCTAssertEqual(usage["scannedSubmissions"] as? Int, 4)
                    let items = try XCTUnwrap(usage["items"] as? [[String: Any]])
                    let used = try XCTUnwrap(items.first { $0["kid"] as? String == source.activeKid })
                    XCTAssertEqual(used["submissions"] as? Int, 2)
                    XCTAssertEqual(used["inKeyStore"] as? Bool, true)
                    XCTAssertEqual(used["formIds"] as? [String], [Self.form])
                    let missing = try XCTUnwrap(items.first { $0["kid"] as? String == source.foreignKid })
                    XCTAssertEqual(missing["submissions"] as? Int, 1)
                    XCTAssertEqual(missing["inKeyStore"] as? Bool, false)
                    XCTAssertEqual(items.count, 2)
                    // Names and references, never credentials.
                    let forms = try XCTUnwrap(json["forms"] as? [[String: Any]])
                    XCTAssertEqual(forms.first?["name"] as? String, "Synthetisches Formular")
                    XCTAssertEqual(forms.first?["connectionIds"] as? [String], ["44444444-4444-4444-8444-444444444444"])
                    let connections = try XCTUnwrap(json["connections"] as? [[String: Any]])
                    XCTAssertEqual(connections.first?["name"] as? String, "Synthetischer Versand")
                    XCTAssertEqual(connections.first?["kind"] as? String, "smtp")
                    for secret in [source.password, "never-in-response", "smtp.example.invalid", "KUBUS-AEAD",
                                   source.active.publicKey.rawRepresentation.base64EncodedString(),
                                   source.active.publicKey.rawRepresentation.base64URLString,
                                   source.active.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined(),
                                   source.foreign.publicKey.rawRepresentation.map { String(format: "%02X", $0) }.joined()] {
                        XCTAssertFalse(text.contains(secret), "response must not contain source secrets, public key bytes or packages")
                    }
                }
            }
        }
    }

    func testKeyInventoryLimitsReportIncompleteScan() async throws {
        try await AdminFixture.with { fx in
            try await withSource(fx) { source in try await self.onSource(fx, source.name) { session in
                let full = try await LegacyKeyInventory.scan(session)
                XCTAssertTrue(full.usageComplete)
                XCTAssertEqual(full.scannedSubmissions, 4)
                // Row limit: stops after two rows and says so; counters are a lower bound, never extrapolated.
                var limits = LegacyKeyInventory.Limits(); limits.maxRows = 2; limits.batch = 1
                let rows = try await LegacyKeyInventory.scan(session, limits: limits)
                XCTAssertFalse(rows.usageComplete)
                XCTAssertEqual(rows.scannedSubmissions, 2)
                XCTAssertEqual(rows.usage.first { $0.kid == source.activeKid }?.submissions, 1)
                // Exactly at the limit with nothing left is complete.
                limits.maxRows = 4
                let exact = try await LegacyKeyInventory.scan(session, limits: limits)
                XCTAssertTrue(exact.usageComplete)
                // Kid limit and key limit.
                limits = LegacyKeyInventory.Limits(); limits.maxKids = 1; limits.maxKeys = 1
                let kids = try await LegacyKeyInventory.scan(session, limits: limits)
                XCTAssertFalse(kids.usageComplete)
                XCTAssertEqual(kids.usage.count, 1)
                XCTAssertFalse(kids.keysComplete)
                XCTAssertEqual(kids.keys.count, 1)
                // Time limit.
                var clock = Date(timeIntervalSince1970: 0)
                limits = LegacyKeyInventory.Limits(); limits.batch = 1; limits.seconds = 1
                let timed = try await LegacyKeyInventory.scan(session, limits: limits, now: { clock.addTimeInterval(1); return clock })
                XCTAssertFalse(timed.usageComplete)
                XCTAssertLessThan(timed.scannedSubmissions, 4)
            } }
        }
    }

    func testPackageHeaderParserAcceptsOnlyV2Kids() {
        XCTAssertEqual(LegacyKeyInventory.headerKid(Data("KUBUS-AEAD:2|0123456789abcdef|hpke".utf8)), "0123456789abcdef")
        for wire in ["KUBUS-AEAD:1|0123456789abcdef|x", "KUBUS-AEAD:2|0123456789ABCDEF|hpke", "KUBUS-AEAD:2|0123456789abcde|hpke", "abc:def:ghi", ""] {
            XCTAssertNil(LegacyKeyInventory.headerKid(Data(wire.utf8)), wire)
        }
    }
}
