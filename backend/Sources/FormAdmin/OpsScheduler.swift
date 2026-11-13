// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormMail
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Global mail budget across replicas and priorities. Claim is persisted before SMTP: no automatic resend after uncertainty.
struct OpsScheduler: LifecycleHandler {
    let db: Database, secrets: SecretStore
    let allowedNets: [CIDR], allowInsecure: Bool
    let now: @Sendable () -> Date
    struct Lock: Decodable { let l: Int? }
    struct State: Decodable { let suppressed: UInt64; let suppressed_priority: Int; let due: Int }
    struct Connection: Decodable { let kind: String, safe_config_json: String; let credential_ref: String? }
    static func shouldSend(count: UInt64, suppressed: UInt64, due: Bool) -> Bool { due && (count > 0 || suppressed > 0) }
    func run() async throws {
        try await (db as! SQLDatabase).withSession { sql in
            guard try await sql.raw("SELECT GET_LOCK('form_ops_alarm',0) AS l").first(decoding: Lock.self)?.l == 1 else { return }
            do { try await alarm(sql); try await sql.raw("SELECT RELEASE_LOCK('form_ops_alarm')").run() }
            catch { _ = try? await sql.raw("SELECT RELEASE_LOCK('form_ops_alarm')").run(); throw error }
        }
    }
    func alarm(_ sql: SQLDatabase, send: (any MailTransport, MailMessage) async throws -> Void = { transport, message in try await transport.send(message) }) async throws {
        let stored = try await SystemSettings.read(sql)
        func setting(_ key: String) throws -> String {
            let entry = SettingsRegistry.entries.first { $0.key == key }!
            return try SettingsRegistry.resolve(entry, env: ProcessInfo.processInfo.environment, stored: stored).value!
        }
        let recipient = try setting("ops.recipient"), sender = try setting("ops.sender"), connection = try setting("ops.connection")
        guard !recipient.isEmpty, !sender.isEmpty, let connectionID = UUID(uuidString: connection) else { return }
        let threshold = Int(try setting("ops.threshold"))!, interval = Int(try setting("ops.intervalSeconds"))!
        // Validate connection and resolve credentials before crossing the send barrier.
        guard let conn = try await sql.raw("SELECT kind,safe_config_json,credential_ref FROM connections WHERE id=\(bind: DB.bin(connectionID)) AND enabled=1 AND kind IN ('smtp','mail-proxy')").first(decoding: Connection.self),
              let config = try JSONSerialization.jsonObject(with: Data(conn.safe_config_json.utf8)) as? [String: Any] else { throw Abort(.serviceUnavailable) }
        var secret: String?
        if let ref = conn.credential_ref { secret = try await secrets.get(ref).flatMap { String(data: $0, encoding: .utf8) } }
        let transport = try MailConnection.transport(kind: conn.kind, safeConfig: config, secret: secret, allowedNets: allowedNets, allowInsecure: allowInsecure)
        guard let claim = try await self.claim(sql, threshold: threshold, interval: interval) else { return }
        do {
            let message = try MailMessage(fromAddress: sender, to: [recipient], subject: "Betriebsalarm – Priorität \(claim.priority)", body: "Neue Ereignisse: \(claim.count). Unterdrückte Wiederholungen: \(claim.suppressed). Details stehen unter Betrieb in der Administration.", isHTML: false, date: now())
            _ = try message.rfc822()
            try await send(transport, message)
            try await sql.raw("UPDATE ops_alarm_state SET outcome='accepted' WHERE singleton=1").run()
        } catch {
            try await sql.raw("UPDATE ops_alarm_state SET outcome='failed' WHERE singleton=1").run()
            throw error
        }
    }
    struct Pending: Decodable { let id: UInt64; let priority: Int }
    struct Claim { let count: UInt64, suppressed: UInt64; let priority: Int }
    /// Exactly these committed rows are acknowledged; an older auto-ID that commits later stays pending.
    func claim(_ database: SQLDatabase, threshold: Int, interval: Int) async throws -> Claim? {
        try await database.withSession { sql in
            try await sql.raw("START TRANSACTION").run()
            do {
                let cutoff = DB.time(now().addingTimeInterval(-Double(interval)))
                let state = try await sql.raw("SELECT suppressed,suppressed_priority,(last_sent_at IS NULL OR last_sent_at <= \(bind: cutoff)) AS due FROM ops_alarm_state WHERE singleton=1 FOR UPDATE").first(decoding: State.self)!
                let rows = try await sql.raw("SELECT id,priority FROM ops_events WHERE alarm_seen=0 ORDER BY id LIMIT 1000 FOR UPDATE").all(decoding: Pending.self)
                let count = UInt64(rows.filter { $0.priority >= threshold }.count)
                let priority = max(rows.map(\.priority).max() ?? 0, state.suppressed_priority, threshold)
                let should = Self.shouldSend(count: count, suppressed: state.suppressed, due: state.due == 1)
                if should {
                    try await sql.raw("UPDATE ops_alarm_state SET last_sent_at=\(bind: DB.time(now())),suppressed=0,suppressed_priority=0,outcome='claimed' WHERE singleton=1").run()
                } else {
                    try await sql.raw("UPDATE ops_alarm_state SET suppressed=suppressed+\(bind: count),suppressed_priority=GREATEST(suppressed_priority,\(bind: count == 0 ? 0 : priority)) WHERE singleton=1").run()
                }
                if !rows.isEmpty {
                    // Only database-decoded unsigned integer IDs become SQL syntax.
                    let ids = rows.map { String($0.id) }.joined(separator: ",")
                    try await sql.raw("UPDATE ops_events SET alarm_seen=1 WHERE id IN (\(unsafeRaw: ids))").run()
                }
                try await sql.raw("COMMIT").run()
                return should ? Claim(count: count, suppressed: state.suppressed, priority: priority) : nil
            } catch {
                _ = try? await sql.raw("ROLLBACK").run()
                throw error
            }
        }
    }

    func didBoot(_ app: Application) throws {
        app.storage[OpsTaskKey.self] = Task {
            while !Task.isCancelled {
                do { try await run() } catch { app.logger.warning("ops alarm failed") }
                do { try await OpsMaintenance.purgeAbuse(self.db as! SQLDatabase, now: now()) } catch { app.logger.warning("abuse cleanup failed") }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    func shutdown(_ app: Application) { app.storage[OpsTaskKey.self]?.cancel() }
}
private struct OpsTaskKey: StorageKey { typealias Value = Task<Void, Never> }
