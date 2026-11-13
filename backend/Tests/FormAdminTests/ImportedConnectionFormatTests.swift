// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

/// Operator path, finding C (13.11.2026): the import writes mail connections in the native schema (what `POST /connections` and the
/// transports read) whenever the legacy values allow it, still disabled; values that do not fit stay in the legacy format (activation
/// names the reason). A repeated run over the same target raises no conflict.
extension ImportRehearsalTests {
    func testImportWritesNativeMailConnectionsDisabled() async throws {
        try await withHarness { h in
            let id = try await importedJob(h)
            struct Conn: Decodable { let safe_config_json: String; let credential_ref: String?; let enabled: Int }
            func row(_ uuid: String) async throws -> Conn {
                let fetched = try await h.fx.sql.raw(SQLQueryString("SELECT safe_config_json, credential_ref, enabled FROM connections WHERE id=\(unhexUUID(uuid))")).first(decoding: Conn.self)
                return try XCTUnwrap(fetched)
            }
            let store = SecretStore(db: h.fx.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 31, count: 32)))
            // smtpA: 'tls' on 587 with user and password -> native STARTTLS, the password is the credential
            let a = try await row(RehearsalSource.smtpA)
            XCTAssertEqual(a.enabled, 0, "imported connections stay disabled until activated")
            let cfg = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(a.safe_config_json.utf8)) as? [String: Any])
            XCTAssertEqual(cfg["host"] as? String, "smtp.example.invalid")
            XCTAssertEqual(cfg["port"] as? Int, 587)
            XCTAssertEqual(cfg["security"] as? String, "starttls")
            XCTAssertEqual(cfg["username"] as? String, "mailer@example.invalid")
            XCTAssertEqual(cfg["verifyCertificate"] as? Bool, true)
            let secret = try await store.get(try XCTUnwrap(a.credential_ref)).map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(secret, RehearsalSource.smtpPassword)
            // smtpTest: no encryption with self-signed allowed -> not a valid native connection, stays legacy (verifyCertificate false kept)
            let t = try await row(RehearsalSource.smtpTest)
            XCTAssertTrue(t.safe_config_json.contains("SMTPHost"), "kept in the legacy format")
            // proxy: URL with user info -> stays protected in the legacy format, never in clear in the config
            let p = try await row(RehearsalSource.proxy)
            XCTAssertFalse(p.safe_config_json.contains("proxy-secret"), p.safe_config_json)
            XCTAssertTrue(p.safe_config_json.contains("legacyURLProtected"))
            // repetition over the same target: the job resumes and ends in review without conflict, nothing changes
            let before = try await h.scalar("SELECT MD5(GROUP_CONCAT(CONCAT(HEX(id),safe_config_json,enabled) ORDER BY id)) AS v FROM connections")
            try await h.fx.sql.raw("UPDATE migration_jobs SET state='paused'").run()
            let resumed = try await h.action(id, "resume"); XCTAssertEqual(resumed, .ok)
            try await h.service.tick()
            let state = try await stateOf(h, id)
            XCTAssertEqual(state["state"] as? String, "review", "error=\(state["error"] ?? "-")")
            let after = try await h.scalar("SELECT MD5(GROUP_CONCAT(CONCAT(HEX(id),safe_config_json,enabled) ORDER BY id)) AS v FROM connections")
            XCTAssertEqual(before, after)
        }
    }
}
