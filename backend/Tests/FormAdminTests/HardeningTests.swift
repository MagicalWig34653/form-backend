// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormCore
import FormPersistence
import Foundation
import Logging
import SQLKit
import XCTVapor
import XCTest

/// Captures every log line (message and metadata) in memory.
final class LogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    var logger: Logger {
        var l = Logger(label: "capture") { _ in Handler(capture: self) }
        l.logLevel = .trace
        return l
    }
    struct Handler: LogHandler {
        let capture: LogCapture
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .trace
        subscript(metadataKey key: String) -> Logger.Metadata.Value? {
            get { metadata[key] }
            set { metadata[key] = newValue }
        }
        func log(level: Logger.Level, message: Logger.Message, metadata explicit: Logger.Metadata?, source: String, file: String, function: String, line: UInt) {
            capture.add("\(message) \(explicit ?? [:]) \(metadata)")
        }
    }
}

/// FA-136/FA-148 migration integrity, FA-135 abuse-ban cleanup, FA-141 secrets in logs. Needs MariaDB (skipped otherwise).
final class HardeningTests: XCTestCase {
    struct N: Decodable { let n: Int }

    func testChangedChecksumRejectedAndMissingTableDetected() async throws {
        try await AdminFixture.with { fx in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString).sql")
            defer { try? FileManager.default.removeItem(at: file) }
            try "CREATE TABLE hard_one (id INT PRIMARY KEY);\nCREATE TABLE hard_two (id INT PRIMARY KEY);".write(to: file, atomically: true, encoding: .utf8)
            let runner = MigrationRunner(db: fx.sql)
            let first = try await runner.run(schemaFile: file.path, name: "hard-test")
            XCTAssertEqual(first, .applied(statements: 2))
            let again = try await runner.run(schemaFile: file.path, name: "hard-test")
            XCTAssertEqual(again, .alreadyApplied)
            let none = try await runner.missingTables(schemaFile: file.path)
            XCTAssertEqual(none, [])
            // A missing table is reported; nothing is altered or repaired.
            try await fx.sql.raw("DROP TABLE hard_two").run()
            let missing = try await runner.missingTables(schemaFile: file.path)
            XCTAssertEqual(missing, ["hard_two"])
            // A changed script for an applied migration is refused.
            try "CREATE TABLE hard_one (id INT PRIMARY KEY);\nCREATE TABLE hard_two (id BIGINT PRIMARY KEY);".write(to: file, atomically: true, encoding: .utf8)
            do { _ = try await runner.run(schemaFile: file.path, name: "hard-test"); XCTFail("expected checksumMismatch") }
            catch MigrationError.checksumMismatch(let name) { XCTAssertEqual(name, "hard-test") }
        }
    }

    func testExpiredAbuseBansArePurgedActiveKept() async throws {
        try await AdminFixture.with { fx in
            let now = Date(), form = try await fx.form(customer: try await fx.customer())
            func row(_ tag: UInt8, windowStart: Date, blockedUntil: Date?) async throws {
                try await fx.sql.raw("INSERT INTO ingest_abuse_ips (form_id, ip_digest, hits, window_start, blocked_until) VALUES (\(bind: DB.bin(form)), \(bind: Blob(Data(repeating: tag, count: 32))), 3, \(bind: DB.time(windowStart)), \(bind: blockedUntil.map { DB.time($0) }))").run()
            }
            try await row(1, windowStart: now.addingTimeInterval(-7200), blockedUntil: now.addingTimeInterval(-60))   // expired ban
            try await row(2, windowStart: now.addingTimeInterval(-7200), blockedUntil: nil)                           // stale counter
            try await row(3, windowStart: now.addingTimeInterval(-7200), blockedUntil: now.addingTimeInterval(600))   // active ban
            try await row(4, windowStart: now, blockedUntil: nil)                                                     // fresh counter
            let deleted = try await OpsMaintenance.purgeAbuse(fx.sql, now: now)
            XCTAssertEqual(deleted, 2)
            let left = try await fx.sql.raw("SELECT COUNT(*) AS n FROM ingest_abuse_ips").first(decoding: N.self)!.n
            XCTAssertEqual(left, 2)
        }
    }

    func testSyntheticSecretsStayOutOfLogsAndErrorResponses() async throws {
        try await AdminFixture.with { fx in
            let capture = LogCapture()
            fx.app.logger = capture.logger
            let secrets = ["synthetic-password-Q9x", "synthetic-smtp-pass-7Lm", "synthetic-turnstile-secret-4Rt", "synthetic-token-Zk2", "synthetic-server-key-Hw8"]
            func clean(_ res: XCTHTTPResponse, _ what: String) {
                let body = res.body.string
                for s in secrets { XCTAssertFalse(body.contains(s), "\(what): response leaks \(s)") }
            }
            let account = try await fx.account(), customer = try await fx.customer()
            let form = try await fx.form(customer: customer)
            try await fx.grant(account, "system.manage", system: true, by: account)
            try await fx.grant(account, "draft.write", customer: customer, by: account)
            let user = try await fx.login(account)
            // Configuration with an SMTP password; a rejected variant that puts the secret into config.
            try await user.send(.POST, "connections", body: #"{"kind":"smtp","name":"S","config":{"host":"127.0.0.1","port":2525,"security":"plain"},"credential":"synthetic-smtp-pass-7Lm"}"#) { clean($0, "connection") }
            try await user.send(.POST, "connections", body: #"{"kind":"smtp","name":"S","config":{"host":"127.0.0.1","port":2525,"security":"plain","password":"synthetic-smtp-pass-7Lm"}}"#) { res in
                XCTAssertGreaterThanOrEqual(res.status.code, 400); clean(res, "connection-invalid")
            }
            // Captcha (Turnstile) secret on the form.
            try await user.send(.PUT, "tenants/\(customer.uuidString.lowercased())/forms/\(form.uuidString.lowercased())/abuse-secret", body: #"{"secret":"synthetic-turnstile-secret-4Rt"}"#) { clean($0, "abuse-secret") }
            // Failed second factor with a wrong password.
            try await user.send(.POST, "auth/second-factor/password", body: #"{"method":"password","password":"synthetic-password-Q9x"}"#) { res in
                XCTAssertGreaterThanOrEqual(res.status.code, 400); clean(res, "login")
            }
            // Bearer token and server key as request material on a protected route and on ingest.
            try await fx.app.test(.GET, "admin/api/v1/connections", headers: ["Authorization": "Bearer synthetic-token-Zk2", "X-Api-Key": "synthetic-server-key-Hw8"]) { clean($0, "token") }
            var h = HTTPHeaders()
            h.add(name: .authorization, value: "Bearer synthetic-token-Zk2")
            h.add(name: .contentType, value: "application/x-www-form-urlencoded")
            try await fx.app.test(.POST, "api/v2/submit/?f=\(UUID().uuidString.lowercased())", headers: h, body: ByteBuffer(string: "cf-turnstile-response=synthetic-turnstile-secret-4Rt&key=synthetic-server-key-Hw8")) { res in
                XCTAssertGreaterThanOrEqual(res.status.code, 400); clean(res, "ingest")
            }
            let logs = capture.text
            for s in secrets { XCTAssertFalse(logs.contains(s), "log output leaks \(s)") }
        }
    }
}
