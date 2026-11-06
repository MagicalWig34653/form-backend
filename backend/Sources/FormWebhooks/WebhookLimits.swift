// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormPersistence
import FormCore
import SQLKit
import Vapor

public struct WebhookLimits: Sendable {
    public let perForm: Int, perCustomer: Int, backlog: Int
    public init(perForm: Int = WebhookLimits.env("FORM_WEBHOOK_MAX_PER_FORM", 5),
                perCustomer: Int = WebhookLimits.env("FORM_WEBHOOK_MAX_PER_CUSTOMER", 20),
                backlog: Int = WebhookLimits.env("FORM_WEBHOOK_MAX_BACKLOG_PER_CUSTOMER", 1000)) {
        self.perForm = max(0, perForm); self.perCustomer = max(0, perCustomer); self.backlog = max(0, backlog)
    }
    public static func env(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil } ?? fallback
    }
    public static func current(_ sql: SQLDatabase) async throws -> WebhookLimits {
        let stored = try await SystemSettings.read(sql)
        func number(_ key: String) throws -> Int {
            let entry = SettingsRegistry.entries.first { $0.key == key }!
            return Int(try SettingsRegistry.resolve(entry, env: ProcessInfo.processInfo.environment, stored: stored).value!)!
        }
        return try WebhookLimits(perForm: number("webhook.perForm"), perCustomer: number("webhook.perCustomer"), backlog: number("webhook.backlog"))
    }
    struct ID: Decodable { let id: Blob }
    struct Count: Decodable { let c: Int }
    // Common mutex for create/enable and ingest, always before locking endpoints.
    public static func lockCustomer(_ sql: SQLDatabase, customer: Blob) async throws {
        _ = try await sql.raw("SELECT id FROM customers WHERE id = \(bind: customer) FOR UPDATE").first(decoding: ID.self)
    }
    public func checkActivation(_ sql: SQLDatabase, customer: Blob, form: Blob, excluding: Blob) async throws {
        let total = try await sql.raw("SELECT COUNT(*) AS c FROM webhook_endpoints WHERE customer_id = \(bind: customer) AND active = 1 AND id <> \(bind: excluding) LOCK IN SHARE MODE").first(decoding: Count.self)!.c
        let local = try await sql.raw("SELECT COUNT(*) AS c FROM webhook_endpoints WHERE customer_id = \(bind: customer) AND form_id = \(bind: form) AND active = 1 AND id <> \(bind: excluding) LOCK IN SHARE MODE").first(decoding: Count.self)!.c
        guard total < perCustomer, local < perForm else {
            throw Abort(.unprocessableEntity, reason: "Limit aktiver Webhooks für Formular oder Kunde erreicht")
        }
    }
    /// Caller holds the customer mutex in the submission transaction. Terminal metadata does not consume backlog capacity.
    public func enqueue(_ sql: SQLDatabase, customer: Blob, form: Blob, submission: Blob, at: String) async throws {
        let hooks = try await sql.raw("SELECT id FROM webhook_endpoints WHERE customer_id = \(bind: customer) AND form_id = \(bind: form) AND active = 1 ORDER BY id LOCK IN SHARE MODE").all(decoding: ID.self)
        var pending = try await sql.raw("SELECT COUNT(*) AS c FROM webhook_outbox WHERE customer_id = \(bind: customer) AND state IN ('ready', 'leased') LOCK IN SHARE MODE").first(decoding: Count.self)!.c
        for hook in hooks {
            let full = pending >= backlog
            try await sql.raw("""
                INSERT INTO webhook_outbox (id, customer_id, form_id, webhook_id, submission_id, received_at, state, attempts, next_attempt_at, created_at, completed_at, last_error_code)
                VALUES (\(bind: DB.bin(UUID())), \(bind: customer), \(bind: form), \(bind: hook.id), \(bind: submission), \(bind: at),
                  \(bind: full ? "failed-terminal" : "ready"), 0, \(bind: full ? nil : at), \(bind: at), \(bind: full ? at : nil), \(bind: full ? "backlog" : nil))
                """).run()
            if !full { pending += 1 }
        }
    }
}
