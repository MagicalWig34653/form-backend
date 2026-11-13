// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAuth

/// Scratch MariaDB database with the real schema per test. Needs P4A_DB_PORT/P4A_DB_PASSWORD
/// (backend/integration-test.sh), otherwise the test is skipped. Synthetic data only.
struct DBFixture {
    let app: Application
    var sql: SQLDatabase { Persistence.sql(app) }

    static func with(_ body: (DBFixture) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"].flatMap(Int.init), let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        func cfg(_ db: String) throws -> AppConfig {
            try AppConfig(env: ["FORM_DB_HOST": ProcessInfo.processInfo.environment["P4A_DB_HOST"] ?? "127.0.0.1", "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root", "FORM_DB_NAME": db,
                                "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
        }
        let name = "p5b_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        let admin = try await Application.make(.testing)
        Persistence.configure(admin, try cfg("p4atest"))
        let adminSQL = Persistence.sql(admin)
        try await adminSQL.raw("CREATE DATABASE \(ident: name)").run()
        func cleanup() async { try? await adminSQL.raw("DROP DATABASE IF EXISTS \(ident: name)").run(); try? await admin.asyncShutdown() }
        let app: Application
        do { app = try await Application.make(.testing) } catch { await cleanup(); throw error }
        do {
            Persistence.configure(app, try cfg(name))
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
            _ = try await MigrationRunner(db: Persistence.sql(app)).run(schemaFile: schema)
            try await body(DBFixture(app: app))
        } catch {
            try? await app.asyncShutdown(); await cleanup(); throw error
        }
        try await app.asyncShutdown(); await cleanup()
    }

    /// Inserts a synthetic active account; returns its id.
    func account(active: Bool = true, passwordHash: String = "x") async throws -> UUID {
        let id = UUID()
        try await sql.raw("""
            INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
            VALUES (\(bind: DB.bin(id)), \(bind: "user-" + id.uuidString), \(bind: passwordHash), \(bind: active ? 1 : 0), 0, 0, '2026-10-30 12:00:00.000000')
            """).run()
        return id
    }
}
