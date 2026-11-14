// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormHTTP
@testable import FormPersistence
import Foundation
#if canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#endif
import SQLKit
import XCTest
import XCTVapor

/// Unit tests run without a database. Integration tests need P4A_DB_PORT and P4A_DB_PASSWORD
/// (set by backend/integration-test.sh against a throw-away Docker MariaDB); otherwise skipped.
/// Each DB test works in its own scratch database (created and dropped by the test).
final class HTTPTests: XCTestCase {
    private func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }
    private struct C: Decodable { let c: Int }
    private struct L: Decodable { let l: Int? }

    private func withApp(port: Int, password: String = "synthetic-unused", dbName: String = "p4atest",
                         _ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let cfg = try AppConfig(env: [
                "FORM_DB_HOST": password == "synthetic-unused" ? "127.0.0.1" : (ProcessInfo.processInfo.environment["P4A_DB_HOST"] ?? "127.0.0.1"),
                "FORM_DB_PASSWORD": password, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root",
                "FORM_DB_NAME": dbName, "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1",
            ])
            Persistence.configure(app, cfg)
            try HTTPSetup.configure(app)
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func dbEnv() throws -> (port: Int, password: String) {
        guard let port = env("P4A_DB_PORT").flatMap(Int.init), let pw = env("P4A_DB_PASSWORD") else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        return (port, pw)
    }

    /// Creates a scratch database, runs `body(name)`, always drops it.
    private func withScratchDB(_ body: (_ port: Int, _ password: String, _ name: String) async throws -> Void) async throws {
        let (port, pw) = try dbEnv()
        let name = "p4a_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        try await withApp(port: port, password: pw) { admin in
            let sql = Persistence.sql(admin)
            try await sql.raw("CREATE DATABASE \(ident: name)").run()
            do { try await body(port, pw, name) } catch {
                try? await sql.raw("DROP DATABASE IF EXISTS \(ident: name)").run()
                throw error
            }
            try await sql.raw("DROP DATABASE IF EXISTS \(ident: name)").run()
        }
    }

    private var schemaPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
    }
    private func expectedTableCount() throws -> Int {
        let script = try String(contentsOfFile: schemaPath, encoding: .utf8)
        return script.components(separatedBy: "\n").filter { $0.hasPrefix("CREATE TABLE ") }.count
    }
    private func tempScript(_ text: String) throws -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p4a-\(UUID().uuidString).sql")
        try Data(text.utf8).write(to: url)
        return url.path
    }

    func testHealthWithoutDatabase() async throws {
        try await withApp(port: 1) { app in  // nothing listens on port 1
            try await app.test(.GET, "health") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, #"{"status":"ok"}"#)
                XCTAssertNotNil(res.headers.first(name: "X-Request-Id"))
                XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
            }
            try await app.test(.GET, "nope") { res async throws in
                XCTAssertEqual(res.status, .notFound)
                let p = try JSONDecoder().decode(Problem.self, from: res.body)
                XCTAssertEqual(p.code, "not_found")
                XCTAssertFalse(p.requestId.isEmpty)
            }
        }
    }

    func testClientErrorEnvelopeIsDifferentiated() async throws {
        try await withApp(port: 1) { app in
            let cases: [(HTTPResponseStatus, String)] = [
                (.badRequest, "bad_request"), (.unauthorized, "unauthenticated"), (.forbidden, "forbidden"),
                (.methodNotAllowed, "method_not_allowed"), (.conflict, "conflict"), (.payloadTooLarge, "payload_too_large"),
                (.unsupportedMediaType, "unsupported_media_type"), (.unprocessableEntity, "validation_failed"),
                (.tooManyRequests, "rate_limited"), (.imATeapot, "bad_request"),
            ]
            for (status, _) in cases { app.get("t\(status.code)") { _ -> String in throw Abort(status, reason: "secret-reason-xyz") } }
            for (status, code) in cases {
                try await app.test(.GET, "t\(status.code)") { res async throws in
                    XCTAssertEqual(res.status, status)
                    let p = try JSONDecoder().decode(Problem.self, from: res.body)
                    XCTAssertEqual(p.code, code)
                    XCTAssertFalse(res.body.string.contains("secret-reason-xyz"))
                    XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
                    XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
                }
            }
            app.get("boom") { _ -> String in struct Secret: Error {}; throw Secret() }
            try await app.test(.GET, "boom") { res async throws in
                XCTAssertEqual(res.status, .internalServerError)
                XCTAssertEqual(try JSONDecoder().decode(Problem.self, from: res.body).code, "internal_error")
            }
        }
    }

    private actor DeadlockLatch {
        private var hits = 0
        func hit() { hits += 1 }
        func wait(for n: Int) async { while hits < n { try? await Task.sleep(nanoseconds: 10_000_000) } }
    }

    /// Regression (operator run, PUT key-rotation/objects): a deadlock victim (MySQL 1213, transaction rolled back as a whole) is a lock race
    /// the client repeats, not an internal error: 409 on the admin API, unchanged 500 elsewhere (public ingest has its own retry).
    func testDatabaseDeadlockVictimIsConflictOnAdminApiNotInternalError() async throws {
        let (port, pw) = try dbEnv()
        try await withApp(port: port, password: pw) { app in
            let sql = Persistence.sql(app)
            let table = "dl_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
            try await sql.raw("CREATE TABLE \(ident: table) (id INT PRIMARY KEY, v INT NOT NULL) ENGINE=InnoDB").run()
            try await sql.raw("INSERT INTO \(ident: table) (id, v) VALUES (1, 0), (2, 0)").run()
            defer { Task { try? await sql.raw("DROP TABLE IF EXISTS \(ident: table)").run() } }
            let latch = DeadlockLatch()
            func crossing(first: Int, second: Int) async -> Error? {
                do {
                    try await app.db(.mysql).transaction { conn in
                        let tx = conn as! SQLDatabase
                        try await tx.raw("UPDATE \(ident: table) SET v = v + 1 WHERE id = \(literal: first)").run()
                        await latch.hit()
                        await latch.wait(for: 2)
                        try await tx.raw("UPDATE \(ident: table) SET v = v + 1 WHERE id = \(literal: second)").run()
                    }
                    return nil
                } catch { return error }
            }
            async let a = crossing(first: 1, second: 2)
            async let b = crossing(first: 2, second: 1)
            let failures = await [a, b].compactMap { $0 }
            XCTAssertEqual(failures.count, 1, "exactly one transaction is the deadlock victim")
            let victim = try XCTUnwrap(failures.first)
            XCTAssertTrue(DB.isTransientConflict(victim), "\(DB.logDescription(victim))")
            XCTAssertFalse(DB.isTransientConflict(Abort(.notFound)))
            app.get("admin", "api", "v1", "race") { _ -> String in throw victim }
            app.get("public", "race") { _ -> String in throw victim }
            try await app.test(.GET, "admin/api/v1/race") { res async throws in
                XCTAssertEqual(res.status, .conflict)
                XCTAssertEqual(try JSONDecoder().decode(Problem.self, from: res.body).code, "conflict")
                XCTAssertFalse(res.body.string.contains("1213"))
            }
            try await app.test(.GET, "public/race") { res async in XCTAssertEqual(res.status, .internalServerError) }
        }
    }

    func testReadyIs503WhenDatabaseDown() async throws {
        try await withApp(port: 1) { app in
            try await app.test(.GET, "ready") { res async throws in
                XCTAssertEqual(res.status, .serviceUnavailable)
                XCTAssertEqual(try JSONDecoder().decode(Problem.self, from: res.body).code, "not_ready")
            }
        }
    }

    /// A server that accepts the TCP connection but never answers the MySQL handshake must not hang /ready.
    func testReadyTimesOutWhenDatabaseHangs() async throws {
        #if canImport(Glibc)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let listener = socket(AF_INET, streamType, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(listener, 8), 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        try await withApp(port: port) { app in
            let start = Date()
            let ok = await Persistence.ping(app, timeoutSeconds: 0.5)
            XCTAssertFalse(ok)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testRunnerRejectsUnterminatedScriptsBeforeTouchingDatabase() async throws {
        try await withApp(port: 1) { app in
            let runner = MigrationRunner(db: Persistence.sql(app))
            for bad in ["CREATE TABLE a (x INT); /* never closed", "CREATE TABLE a (x INT COMMENT 'open"] {
                do { _ = try await runner.run(schemaFile: try tempScript(bad)); XCTFail("expected error") } catch let e as MigrationError {
                    guard case .scriptInvalid = e else { return XCTFail("wrong error \(e)") }
                }
            }
        }
    }

    func testMigrationExactTableCountIdempotentAndReadyAgainstMariaDB() async throws {
        try await withScratchDB { port, pw, name in
            try await withApp(port: port, password: pw, dbName: name) { app in
                let sql = Persistence.sql(app)
                let runner = MigrationRunner(db: sql)
                let expected = try expectedTableCount()
                let script = try String(contentsOfFile: schemaPath, encoding: .utf8)
                let statements = try SQLStatementSplitter.split(script)
                XCTAssertEqual(statements.filter { $0.hasPrefix("CREATE TABLE ") }.count, expected)

                let first = try await runner.run(schemaFile: schemaPath)
                XCTAssertEqual(first, .applied(statements: statements.count))
                let again = try await runner.run(schemaFile: schemaPath)
                XCTAssertEqual(again, .alreadyApplied)

                let rows = try await sql.raw("SELECT COUNT(*) AS c FROM schema_migrations").first(decoding: C.self)
                XCTAssertEqual(rows?.c, 1)
                let tables = try await sql.raw("SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema = DATABASE()")
                    .first(decoding: C.self)
                XCTAssertEqual(tables?.c, expected + 1)  // + schema_migrations

                // Tampered checksum must be refused.
                try await sql.raw("UPDATE schema_migrations SET checksum = REPEAT('0', 64)").run()
                do { _ = try await runner.run(schemaFile: schemaPath); XCTFail("expected checksum mismatch") } catch {
                    XCTAssertTrue("\(error)".contains("different checksum"))
                }
                try await app.test(.GET, "ready") { res async in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertEqual(res.body.string, #"{"status":"ready"}"#)
                }
            }
        }
    }

    /// Two runners (two separate pools, as two processes) race on an empty database: exactly one applies.
    func testParallelRunnersExactlyOneApplies() async throws {
        try await withScratchDB { port, pw, name in
            try await withApp(port: port, password: pw, dbName: name) { a in
                try await withApp(port: port, password: pw, dbName: name) { b in
                    let ra = MigrationRunner(db: Persistence.sql(a)), rb = MigrationRunner(db: Persistence.sql(b))
                    let path = schemaPath
                    async let x = ra.run(schemaFile: path)
                    async let y = rb.run(schemaFile: path)
                    let outcomes = try await [x, y]
                    let applied = outcomes.filter { if case .applied = $0 { return true } else { return false } }
                    XCTAssertEqual(applied.count, 1, "outcomes: \(outcomes)")
                    XCTAssertEqual(outcomes.filter { $0 == .alreadyApplied }.count, 1, "outcomes: \(outcomes)")
                }
            }
            // Same pool, two runners at once (pinned sessions, even with a pool of 2 connections per loop).
            try await withApp(port: port, password: pw, dbName: name) { c in
                let rc = MigrationRunner(db: Persistence.sql(c))
                let path = schemaPath
                async let x = rc.run(schemaFile: path)
                async let y = rc.run(schemaFile: path)
                let both = try await [x, y]
                XCTAssertEqual(both, [.alreadyApplied, .alreadyApplied])
            }
        }
    }

    /// The lock is a real session lock: while another session holds it, the runner must not proceed.
    func testRunnerRespectsForeignLock() async throws {
        try await withScratchDB { port, pw, name in
            try await withApp(port: port, password: pw, dbName: name) { holder in
                try await withApp(port: port, password: pw, dbName: name) { other in
                    let runner = MigrationRunner(db: Persistence.sql(other))
                    let path = schemaPath
                    try await Persistence.sql(holder).withSession { session in
                        let got = try await session.raw("SELECT GET_LOCK(\(literal: MigrationRunner.lockName), 5) AS l").first(decoding: L.self)
                        XCTAssertEqual(got?.l, 1)
                        do { _ = try await runner.run(schemaFile: path, lockTimeoutSeconds: 1); XCTFail("expected lockNotAcquired") } catch let e as MigrationError {
                            guard case .lockNotAcquired = e else { return XCTFail("wrong error \(e)") }
                        }
                        _ = try await session.raw("SELECT RELEASE_LOCK(\(literal: MigrationRunner.lockName))").run()
                    }
                    // After release the same runner proceeds.
                    guard case .applied = try await runner.run(schemaFile: path, lockTimeoutSeconds: 5) else { return XCTFail("expected applied") }
                }
            }
        }
    }

    /// Abort in the middle of a schema: precise error (statement number, server error number, no statement text),
    /// no bookkeeping row, and the re-run reports the partial state instead of failing at statement 1.
    func testInterruptedMigrationReportsAndRerunDetectsPartialState() async throws {
        try await withScratchDB { port, pw, name in
            try await withApp(port: port, password: pw, dbName: name) { app in
                let sql = Persistence.sql(app)
                let runner = MigrationRunner(db: sql)
                // Statement 2 collides with statement 1 (MariaDB error 1050).
                let path = try tempScript("CREATE TABLE sec_a (x INT);\nCREATE TABLE sec_a (y INT);\nCREATE TABLE sec_c (z INT);\n")
                do { _ = try await runner.run(schemaFile: path); XCTFail("expected failure") } catch let e as MigrationError {
                    guard case .statementFailed(let index, let of, let code, _, _) = e else { return XCTFail("wrong error \(e)") }
                    XCTAssertEqual(index, 2); XCTAssertEqual(of, 3); XCTAssertEqual(code, 1050)
                    let text = "\(e)"
                    XCTAssertTrue(text.contains("statement 2/3") && text.contains("1050") && text.contains("DEVELOPMENT DATABASES ONLY"))
                    XCTAssertFalse(text.contains("CREATE TABLE") || text.contains("sec_a"))
                }
                let rows = try await sql.raw("SELECT COUNT(*) AS c FROM schema_migrations").first(decoding: C.self)
                XCTAssertEqual(rows?.c, 0)
                do { _ = try await runner.run(schemaFile: path); XCTFail("expected partial state") } catch let e as MigrationError {
                    guard case .partialState(let existing, let expected) = e else { return XCTFail("wrong error \(e)") }
                    XCTAssertEqual(existing, 1); XCTAssertEqual(expected, 2)
                }
                // Documented reset: drop the partial table(s) and the run succeeds with a corrected script.
                try await sql.raw("DROP TABLE sec_a").run()
                let fixed = try tempScript("CREATE TABLE sec_a (x INT);\nCREATE TABLE sec_c (z INT);\n")
                let fixedOutcome = try await runner.run(schemaFile: fixed, name: "other")
                XCTAssertEqual(fixedOutcome, .applied(statements: 2))
            }
        }
    }

    func testBOMScriptIsAppliedWithoutBOMOnTheWire() async throws {
        try await withScratchDB { port, pw, name in
            try await withApp(port: port, password: pw, dbName: name) { app in
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("p4a-bom-\(UUID().uuidString).sql")
                try (Data([0xEF, 0xBB, 0xBF]) + Data("CREATE TABLE bom_t (x INT);\n".utf8)).write(to: url)
                let runner = MigrationRunner(db: Persistence.sql(app))
                let bomOutcome = try await runner.run(schemaFile: url.path)
                XCTAssertEqual(bomOutcome, .applied(statements: 1))
                XCTAssertEqual(MigrationRunner.decodeUTF8(Data([0xEF, 0xBB, 0xBF, 0x61]))?.unicodeScalars.count, 2)
                XCTAssertNil(MigrationRunner.decodeUTF8(Data([0xFF])))
            }
        }
    }
}

#if canImport(Glibc)
private let sysBind: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32 = { Glibc.bind($0, $1, $2) }
#else
private let sysBind: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32 = { Darwin.bind($0, $1, $2) }
#endif
