// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import FluentMySQLDriver
import SQLKit

public enum MigrationError: Error, CustomStringConvertible {
    case schemaFileUnreadable
    case scriptInvalid(reason: String)
    case checksumMismatch(name: String)
    case lockNotAcquired
    case lockLost
    /// The schema is recorded as applied but tables of the script are missing (manual drop, partial restore).
    case missingTables([String])
    /// A previous run was interrupted: some tables of the script exist but no schema_migrations row.
    case partialState(existingTables: Int, expectedTables: Int)
    /// `code`/`sqlState` are the server's error number and SQLSTATE (no statement text, no values).
    case statementFailed(index: Int, of: Int, code: Int?, sqlState: String?, kind: String)

    /// Documented reset procedure (development databases only; DDL is not transactional in MariaDB).
    public static let resetHint = "DEVELOPMENT DATABASES ONLY, never a database holding real data: drop and recreate the schema, then re-run migrate; "
        + "see docs/handoffs/Code-Review-Korrektur-Backend.md"

    public var description: String {
        switch self {
        case .schemaFileUnreadable: return "schema file not readable or not valid UTF-8"
        case .scriptInvalid(let r): return "schema script invalid: \(r)"
        case .checksumMismatch(let n): return "migration \(n) was applied with a different checksum; refusing to continue"
        case .lockNotAcquired: return "migration lock not acquired"
        case .missingTables(let t): return "schema is recorded as applied but tables are missing: \(t.joined(separator: ", "))"
        case .lockLost: return "migration lock was not held by the migration session at release"
        case .partialState(let e, let n):
            return "partially applied schema detected (\(e) of \(n) tables exist, no schema_migrations row); \(Self.resetHint)"
        case .statementFailed(let i, let n, let code, let state, let kind):
            return "statement \(i)/\(n) failed (\(kind), MariaDB error \(code.map(String.init) ?? "unknown"), SQLSTATE \(state ?? "unknown")); "
                + "statements 1..\(i - 1) are applied and not rolled back; \(Self.resetHint)"
        }
    }
}

public enum MigrationOutcome: Equatable { case applied(statements: Int), alreadyApplied }

/// Applies the DDL file (source of truth: backend/db/schema-p3.sql) once and records it in
/// `schema_migrations`. No Fluent auto-migration.
///
/// Lock, check, all statements and the bookkeeping INSERT run on ONE pinned connection
/// (`SQLDatabase.withSession`): MariaDB named locks belong to the session, so they would not protect
/// anything across pooled connections.
///
/// MariaDB DDL is not transactional: a failure in the middle leaves earlier statements applied and NO
/// schema_migrations row. A re-run detects this (`partialState`) instead of failing at the first
/// CREATE TABLE; recovery is the documented reset (`MigrationError.resetHint`). Not for production.
public struct MigrationRunner {
    public static let schemaName = "schema-p3"
    public static let lockName = "form_schema_migrations"
    let db: SQLDatabase
    public init(db: SQLDatabase) { self.db = db }

    public static func checksum(of script: String) -> String { checksum(ofBytes: Data(script.utf8)) }
    /// Checksum over the exact file bytes (a UTF-8 BOM is part of the file and therefore of the sum).
    public static func checksum(ofBytes data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Validating, BOM-preserving UTF-8 decode (`String(data:encoding:)` may drop a BOM).
    static func decodeUTF8(_ data: Data) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        return s.utf8.elementsEqual(data) ? s : nil
    }

    /// Upgrade scripts `migrate` applies after the schema, in this order, from `upgrades/<name>.sql` next to the schema file. Each
    /// is recorded under its own name and checksum; a schema change after a release is a NEW upgrade here, never an edit of
    /// schema-p3.sql (that would break the checksum of every existing database). Every upgrade must be idempotent.
    public static let upgrades = ["0027-account-recovery", "0033-sdk-deploy-recovery", "0034-retention-default", "0035-imported-no-retention", "0036-api-host-owner"]

    public static func upgradeFile(_ name: String, schemaFile: String) -> String {
        URL(fileURLWithPath: schemaFile).deletingLastPathComponent().appendingPathComponent("upgrades/\(name).sql").path
    }

    /// Schema, then every upgrade of `upgrades`.
    public func runWithUpgrades(schemaFile: String) async throws -> MigrationOutcome {
        let outcome = try await run(schemaFile: schemaFile)
        for name in Self.upgrades { try await run(schemaFile: Self.upgradeFile(name, schemaFile: schemaFile), name: name) }
        return outcome
    }

    @discardableResult
    public func run(schemaFile: String, name: String = MigrationRunner.schemaName, lockTimeoutSeconds: Int = 30) async throws -> MigrationOutcome {
        guard let data = FileManager.default.contents(atPath: schemaFile), var script = Self.decodeUTF8(data) else {
            throw MigrationError.schemaFileUnreadable
        }
        if script.unicodeScalars.first == "\u{FEFF}" { script.unicodeScalars.removeFirst() }  // BOM must not reach the server
        let statements: [String]
        do { statements = try SQLStatementSplitter.split(script) } catch {
            throw MigrationError.scriptInvalid(reason: "\(error)")
        }
        guard !statements.isEmpty else { throw MigrationError.scriptInvalid(reason: "no statements") }
        let sum = Self.checksum(ofBytes: data)
        return try await db.withSession { session in
            let got = try await session.raw("SELECT GET_LOCK(\(literal: Self.lockName), \(unsafeRaw: String(max(0, lockTimeoutSeconds)))) AS l")
                .first(decoding: LockRow.self)
            guard got?.l == 1 else { throw MigrationError.lockNotAcquired }
            let outcome: MigrationOutcome
            do {
                outcome = try await Self.locked(session, name: name, statements: statements, sum: sum)
            } catch {
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: Self.lockName))").run()
                throw error
            }
            let released = try await session.raw("SELECT RELEASE_LOCK(\(literal: Self.lockName)) AS l").first(decoding: LockRow.self)
            guard released?.l == 1 else { throw MigrationError.lockLost }
            return outcome
        }
    }

    /// Read-only schema comparison: tables the script creates that do not exist in the current database (sorted).
    /// Columns are not compared. Never alters the database.
    public func missingTables(schemaFile: String) async throws -> [String] {
        guard let data = FileManager.default.contents(atPath: schemaFile), var script = Self.decodeUTF8(data) else {
            throw MigrationError.schemaFileUnreadable
        }
        if script.unicodeScalars.first == "\u{FEFF}" { script.unicodeScalars.removeFirst() }
        let statements: [String]
        do { statements = try SQLStatementSplitter.split(script) } catch { throw MigrationError.scriptInvalid(reason: "\(error)") }
        let present = Set(try await db.raw("SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE()")
            .all(decoding: TableRow.self).map { $0.t })
        return Set(Self.createdTables(statements)).subtracting(present).sorted()
    }

    private struct LockRow: Decodable { let l: Int? }
    private struct MigRow: Decodable { let checksum: String }
    private struct TableRow: Decodable { let t: String }

    /// Names of the tables a script creates (`CREATE TABLE [IF NOT EXISTS] name`).
    static func createdTables(_ statements: [String]) -> [String] {
        statements.compactMap { stmt in
            guard let r = stmt.range(of: "^CREATE\\s+TABLE\\s+(IF\\s+NOT\\s+EXISTS\\s+)?`?([A-Za-z0-9_$]+)`?", options: [.regularExpression, .caseInsensitive]) else { return nil }
            let head = String(stmt[r])
            return head.split(whereSeparator: { $0.isWhitespace }).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
        }
    }

    private static func locked(_ db: SQLDatabase, name: String, statements: [String], sum: String) async throws -> MigrationOutcome {
        try await db.raw("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
              name VARCHAR(255) NOT NULL PRIMARY KEY,
              checksum CHAR(64) NOT NULL,
              applied_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin
            """).run()
        if let row = try await db.raw("SELECT checksum FROM schema_migrations WHERE name = \(literal: name)")
            .first(decoding: MigRow.self) {
            guard row.checksum == sum else { throw MigrationError.checksumMismatch(name: name) }
            return .alreadyApplied
        }
        // No bookkeeping row: the script must find none of its tables (otherwise an earlier run was interrupted).
        let expected = Set(createdTables(statements))
        let present = Set(try await db.raw("SELECT table_name AS t FROM information_schema.tables WHERE table_schema = DATABASE()")
            .all(decoding: TableRow.self).map { $0.t })
        let existing = expected.filter { present.contains($0) }.count
        guard existing == 0 else { throw MigrationError.partialState(existingTables: existing, expectedTables: expected.count) }
        for (i, stmt) in statements.enumerated() {
            do { try await db.raw(SQLQueryString(stmt)).run() } catch {
                let info = Self.errorInfo(error)
                throw MigrationError.statementFailed(index: i + 1, of: statements.count, code: info.code, sqlState: info.state, kind: info.kind)
            }
        }
        try await db.raw("INSERT INTO schema_migrations (name, checksum) VALUES (\(literal: name), \(literal: sum))").run()
        return .applied(statements: statements.count)
    }

    /// Error number and SQLSTATE only; driver descriptions may echo statement text or values.
    static func errorInfo(_ error: Error) -> (code: Int?, state: String?, kind: String) {
        if let e = error as? MySQLError, case .server(let packet) = e {
            return (Int(packet.errorCode.rawValue), packet.sqlState, "server")
        }
        return (nil, nil, String(describing: type(of: error)))
    }
}
