// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// 422 for an unknown preference key or a value outside the allowlist (fixed text, never request values).
struct PreferencesInvalid: PublicProblemError {
    var statusCode: UInt { 422 }
    var code: String { "validation_failed" }
    var message: String { "Ungültige Darstellungsoption." }
}

/// Display preferences of the signed-in account (`account_preferences`). Only the own account (from the session),
/// harmless values: no fresh authentication and no audit. Allowlist mirrors pwa/src/lib/accents.ts and theme.svelte.ts.
enum AccountPreferenceRoutes {
    static let themes: Set<String> = ["light", "dark", "system"]
    static let accents: Set<String> = [
        "tuerkis", "blau", "violett", "orange", "rot", "gruen", "gelb", "bernstein", "limette", "smaragd",
        "cyan", "himmelblau", "indigo", "purpur", "magenta", "pink", "rose", "koralle", "braun", "schiefer",
    ]
    static let glowRange: ClosedRange<Int64> = 0...6

    /// Validated value for a key, or nil when key or value is not allowed.
    static func validate(_ key: String, _ value: JSONValue) -> JSONValue? {
        switch (key, value) {
        case ("theme", .string(let s)) where themes.contains(s): return value
        case ("accent", .string(let s)) where accents.contains(s): return value
        case ("glow", .int(let n)) where glowRange.contains(n): return value
        default: return nil
        }
    }

    static func register(root: RoutesBuilder, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let path: [PathComponent] = ["me", "preferences"]
        root.get(path) { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            return try response(try await read(db as! SQLDatabase, account: s.accountID!))
        }
        root.on(.PUT, path, body: .collect(maxSize: "4kb")) { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            guard req.headers.contentType == .json else { throw Abort(.unsupportedMediaType) }
            guard let buffer = req.body.data else { throw Abort(.badRequest) }
            let parsed: JSONValue
            do { parsed = try JCS.parse(Data(buffer: buffer)) } catch { throw Abort(.badRequest) }
            guard case .object(let input) = parsed, !input.isEmpty else { throw PreferencesInvalid() }
            var values: [(String, JSONValue)] = []
            for (key, value) in input {
                guard let valid = validate(key, value) else { throw PreferencesInvalid() }
                values.append((key, valid))
            }
            let account = s.accountID!
            let stored = try await db.transaction { conn -> [String: JSONValue] in
                let sql = conn as! SQLDatabase
                let at = DB.time(now())
                for (key, value) in values.sorted(by: { $0.0 < $1.0 }) {
                    let json = String(decoding: JCS.canonicalize(value), as: UTF8.self)
                    try await sql.raw("""
                        INSERT INTO account_preferences (account_id, preference_key, safe_value_json, modified_at)
                        VALUES (\(bind: DB.bin(account)), \(bind: key), \(bind: json), \(bind: at))
                        ON DUPLICATE KEY UPDATE safe_value_json = VALUES(safe_value_json), modified_at = VALUES(modified_at)
                        """).run()
                }
                return try await read(sql, account: account)
            }
            return try response(stored)
        }
    }

    /// Stored, still valid preferences of the account; unknown or outdated rows are left out.
    static func read(_ sql: SQLDatabase, account: UUID) async throws -> [String: JSONValue] {
        struct Row: Decodable { let preference_key: String; let safe_value_json: String }
        let rows = try await sql.raw("SELECT preference_key, safe_value_json FROM account_preferences WHERE account_id = \(bind: DB.bin(account))").all(decoding: Row.self)
        var out: [String: JSONValue] = [:]
        for row in rows {
            guard let value = try? JCS.parse(Data(row.safe_value_json.utf8)), let valid = validate(row.preference_key, value) else { continue }
            out[row.preference_key] = valid
        }
        return out
    }

    static func response(_ values: [String: JSONValue]) throws -> Response {
        let res = Response(status: .ok)
        res.body = .init(data: JCS.canonicalize(.object(values)))
        res.headers.contentType = .json
        res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return res
    }
}
