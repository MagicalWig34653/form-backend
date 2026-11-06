// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormCore
import FormPersistence
import Foundation
import Logging
import Vapor
import SQLKit

/// Resolves the secret of a connection (`credential_ref`); implemented on top of the encrypted SecretStore in the application.
public protocol MailSecretProvider: Sendable {
    func secret(ref: String) async throws -> String?
}

/// One planned mail of a submission, fully rendered in memory. The delivery row exists before any network I/O.
public struct PreparedMail: Sendable {
    public let deliveryID: UUID
    public let leaseToken: UUID
    public let message: MailMessage
    let connection: ConnectionRow?
}

/// Plain JSON values only (decoded from `safe_config_json`), immutable after creation.
struct ConnectionRow { let kind: String; let safeConfig: [String: Any]; let credentialRef: String?
    init(kind: String, safeConfig: [String: Any], credentialRef: String?) { self.kind = kind; self.safeConfig = safeConfig; self.credentialRef = credentialRef }
}
extension ConnectionRow: @unchecked Sendable {}

/// Mail for a submission, WITHOUT ever storing content: rows in `mail_deliveries` carry only identity, state and an error token.
/// `prepare` runs inside the submission's transaction (rows are leased = in flight before I/O, so a crash leaves a visible
/// `leased` row that `expireLeases` turns into `uncertain`); `dispatch` runs after the commit and never blocks the response.
public struct MailDispatcher: Sendable {
    public static let leaseSeconds: TimeInterval = 120
    public static let maxConcurrent = 8, maxQueued = 200

    let db: Database
    let secrets: any MailSecretProvider
    let allowedNets: [CIDR]
    let allowInsecure: Bool
    let now: @Sendable () -> Date
    let logger: Logger
    let queue: SendQueue

    public init(db: Database, secrets: any MailSecretProvider, allowedNets: [CIDR], allowInsecure: Bool, logger: Logger, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.secrets = secrets; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.logger = logger; self.now = now
        queue = SendQueue(maxConcurrent: Self.maxConcurrent, maxQueued: Self.maxQueued)
    }

    private struct ConnQuery: Decodable { let kind: String; let safe_config_json: String; let credential_ref: String?; let enabled: Int }

    /// Parses the plan of a form version definition (nil = no mail configured or invalid → nothing is sent).
    public static func plan(definition: [String: Any]) -> MailPlan? {
        guard let mail = definition["mail"] as? [String: Any] else { return nil }
        var names = Set<String>()
        for (_, f) in (definition["fields"] as? [String: Any]) ?? [:] { if let n = (f as? [String: Any])?["name"] as? String { names.insert(n) } }
        return MailPlan.parse(mail, fieldNames: names).0
    }

    /// Creates the delivery rows (inside `tx`) and renders the messages from the in-memory submission.
    /// `fields` are the submitted fields (`{"name": "value" | [..] | {..}}`).
    public func prepare(tx: SQLDatabase, plan: MailPlan, customer: Blob, form: Blob, submission: UUID, fields: [String: Any], identityScope: String = "form-mail", effectID: UUID? = nil, onlyKind: String? = nil) async throws -> [PreparedMail] {
        var values = MailTemplate.values(fromFields: fields)
        plan.apply(derived: &values, now: now())
        let t = DB.time(now())
        let lease = DB.time(now().addingTimeInterval(Self.leaseSeconds))
        let conn = try await connection(tx, customer: customer, form: form)
        var out: [PreparedMail] = []
        // Only an effect that never crossed the send barrier may reuse a rendered delivery.
        struct Existing: Decodable { let id: Blob }
        var existingID: UUID?
        if let effectID {
            struct Effect: Decodable { let state: String }
            guard try await tx.raw("SELECT state FROM workflow_effects WHERE id=\(bind: DB.bin(effectID)) FOR UPDATE").first(decoding: Effect.self)?.state == "prepared" else { throw ResendError.notResendable }
            existingID = try await tx.raw("SELECT id FROM mail_deliveries WHERE effect_id=\(bind: DB.bin(effectID)) FOR UPDATE").first(decoding: Existing.self).flatMap { DB.uuid($0.id.data) }
        }

        func row(kind: String, state: String, code: String?, token: UUID?, id: UUID) async throws {
            if existingID != nil {
                try await tx.raw("""
                    UPDATE mail_deliveries SET state=\(bind: state),lease_token=\(bind: token.map(DB.bin)),lease_until=\(bind: token == nil ? nil : lease),
                      transport_kind=\(bind: conn?.kind ?? "none"),last_error_code=\(bind: code),updated_at=\(bind: t),fence=fence+1
                    WHERE id=\(bind: DB.bin(id)) AND effect_id=\(bind: effectID.map(DB.bin))
                    """).run()
                return
            }
            try await tx.raw("""
                INSERT INTO mail_deliveries (id, customer_id, form_id, submission_id, environment, mail_kind, identity_scope, effect_id, transport_kind, state, attempts, next_attempt_at,
                  lease_token, lease_until, fence, last_error_code, created_at, updated_at)
                VALUES (\(bind: DB.bin(id)), \(bind: customer), \(bind: form), \(bind: DB.bin(submission)), 'production', \(bind: kind), \(bind: identityScope), \(bind: effectID.map(DB.bin)), \(bind: conn?.kind ?? "none"), \(bind: state), 0, NULL,
                  \(bind: token.map(DB.bin)), \(bind: token == nil ? nil : lease), 0, \(bind: code), \(bind: t), \(bind: t))
                """).run()
        }

        func make(_ kind: String, to: [String], bcc: [String], replyTo: String?, template: MailPlan.Template) async throws {
            let id = existingID ?? UUID()
            guard let conn else { try await row(kind: kind, state: "waiting-manual", code: "no_connection", token: nil, id: id); return }
            do {
                let msg = try MailMessage(fromAddress: plan.fromAddress, fromName: plan.fromName, to: to, bcc: bcc, replyTo: replyTo,
                                          subject: MailTemplate.renderSubject(template.subject, values: values),
                                          body: MailTemplate.render(template.body, values: values, html: template.isHTML), isHTML: template.isHTML, date: now())
                guard try await recipientsAllowed(tx: tx, recipients: to + bcc, submission: submission) else {
                    try await row(kind: kind, state: "abandoned", code: "recipient_not_allowed", token: nil, id: id); return
                }
                _ = try msg.rfc822()   // size/format problems surface now, not at send time
                let token = UUID()
                try await row(kind: kind, state: "leased", code: nil, token: token, id: id)
                out.append(PreparedMail(deliveryID: id, leaseToken: token, message: msg, connection: conn))
            } catch is MailError {
                try await row(kind: kind, state: "abandoned", code: "message_invalid", token: nil, id: id)
            }
        }

        if let o = plan.organisation, onlyKind == nil || onlyKind == "organisation" {
            let reply = o.replyToField.flatMap { values[$0] }.flatMap(MailAddress.parse)
            try await make("organisation", to: o.to, bcc: o.bcc, replyTo: reply, template: o.template)
        }
        if let c = plan.confirmation, onlyKind == nil || onlyKind == "confirmation" {
            if let addr = values[c.toField].flatMap(MailAddress.parse) {
                try await make("confirmation", to: [addr], bcc: [], replyTo: nil, template: c.template)
            } else {
                try await row(kind: "confirmation", state: "abandoned", code: "recipient_invalid", token: nil, id: existingID ?? UUID())   // visible, not silent
            }
        }
        return out
    }

    public enum ResendError: Error { case notResendable, noConnection, kindNotPlanned, recipientInvalid, messageInvalid }

    /// Manual resend of ONE existing delivery (wiederanlauf.md): the message is rendered again from the pinned release's plan and the
    /// submission's own fields (never from client-supplied content), and the SAME row is claimed (waiting-manual/uncertain -> leased).
    /// `uncertain` is only taken over when the caller states that the earlier attempt was checked.
    public func prepareResend(tx: SQLDatabase, plan: MailPlan, customer: Blob, form: Blob, delivery: UUID, kind: String, allowUncertain: Bool, expectedFence: UInt64?, fields: [String: Any]) async throws -> PreparedMail {
        var values = MailTemplate.values(fromFields: fields)
        plan.apply(derived: &values, now: now())
        guard let conn = try await connection(tx, customer: customer, form: form), ["smtp", "mail-proxy"].contains(conn.kind) else { throw ResendError.noConnection }
        let to: [String], bcc: [String], reply: String?, template: MailPlan.Template
        switch kind {
        case "organisation":
            guard let o = plan.organisation else { throw ResendError.kindNotPlanned }
            to = o.to; bcc = o.bcc; reply = o.replyToField.flatMap { values[$0] }.flatMap(MailAddress.parse); template = o.template
        case "confirmation":
            guard let c = plan.confirmation else { throw ResendError.kindNotPlanned }
            guard let addr = values[c.toField].flatMap(MailAddress.parse) else { throw ResendError.recipientInvalid }
            to = [addr]; bcc = []; reply = nil; template = c.template
        default: throw ResendError.kindNotPlanned
        }
        let message: MailMessage
        do {
            message = try MailMessage(fromAddress: plan.fromAddress, fromName: plan.fromName, to: to, bcc: bcc, replyTo: reply,
                                      subject: MailTemplate.renderSubject(template.subject, values: values),
                                      body: MailTemplate.render(template.body, values: values, html: template.isHTML), isHTML: template.isHTML, date: now())
            _ = try message.rfc822()
        } catch { throw ResendError.messageInvalid }
        struct Submission: Decodable { let submission_id: Blob }
        guard let source = try await tx.raw("SELECT submission_id FROM mail_deliveries WHERE id=\(bind: DB.bin(delivery)) AND customer_id=\(bind: customer) AND form_id=\(bind: form)").first(decoding: Submission.self),
              let submission = DB.uuid(source.submission_id.data), try await recipientsAllowed(tx: tx, recipients: to + bcc, submission: submission) else { throw ResendError.recipientInvalid }
        let token = UUID(), t = DB.time(now())
        let states = allowUncertain ? "'waiting-manual','uncertain'" : "'waiting-manual'"
        struct N: Decodable { let n: Int }
        try await tx.raw("""
            UPDATE mail_deliveries SET state = 'leased', lease_token = \(bind: DB.bin(token)), lease_until = \(bind: DB.time(now().addingTimeInterval(Self.sendLeaseSeconds))),
              fence = fence + 1, transport_kind = \(bind: conn.kind), updated_at = \(bind: t)
            WHERE id = \(bind: DB.bin(delivery)) AND effect_id IS NULL AND customer_id=\(bind: customer) AND form_id=\(bind: form) AND state IN (\(unsafeRaw: states))
              \(unsafeRaw: expectedFence == nil ? "" : "AND fence = \(expectedFence!)")
            """).run()
        guard try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n ?? 0 == 1 else { throw ResendError.notResendable }
        return PreparedMail(deliveryID: delivery, leaseToken: token, message: message, connection: conn)
    }

    /// The `mail` section of the form version behind a release (nil when absent or invalid).
    public static func plan(db: SQLDatabase, customer: Blob, form: Blob, release: Blob) async throws -> MailPlan? {
        struct DefRow: Decodable { let definition_json: String }
        guard let r = try await db.raw("""
            SELECT fv.definition_json AS definition_json FROM releases r
            JOIN form_versions fv ON fv.customer_id = r.customer_id AND fv.form_id = r.form_id AND fv.version_no = r.form_version_no
            WHERE r.id = \(bind: release) AND r.customer_id = \(bind: customer) AND r.form_id = \(bind: form)
            """).first(decoding: DefRow.self),
              let def = (try? JSONSerialization.jsonObject(with: Data(r.definition_json.utf8))) as? [String: Any] else { return nil }
        return plan(definition: def)
    }

    private func connection(_ tx: SQLDatabase, customer: Blob, form: Blob) async throws -> ConnectionRow? {
        guard let r = try await tx.raw("""
            SELECT c.kind AS kind, c.safe_config_json AS safe_config_json, c.credential_ref AS credential_ref, c.enabled AS enabled
            FROM form_connections fc JOIN connections c ON c.id = fc.connection_id
            WHERE fc.customer_id = \(bind: customer) AND fc.form_id = \(bind: form) AND fc.environment = 'production' AND fc.purpose = 'mail'
            """).first(decoding: ConnQuery.self), r.enabled == 1, ["smtp", "mail-proxy"].contains(r.kind),
              let cfg = (try? JSONSerialization.jsonObject(with: Data(r.safe_config_json.utf8))) as? [String: Any] else { return nil }
        return ConnectionRow(kind: r.kind, safeConfig: cfg, credentialRef: r.credential_ref)
    }

    /// Starts sending in the background (call after the submission's transaction committed). Never throws, never blocks.
    public func dispatch(_ mails: [PreparedMail]) {
        for m in mails {
            let me = self
            Task.detached { await me.deliver(m) }
        }
    }

    public func deliver(_ m: PreparedMail, beforeSend: (() async throws -> Bool)? = nil) async {
        guard await queue.enter() else { await finish(m, ok: false, code: "busy"); return }
        // The lease started at `prepare`; waiting in the queue may have used it up (review M3). Renew it now, and only send while the row is
        // still ours: a row already turned `uncertain` must never be sent (a manual resend would then duplicate it).
        guard await renewLease(m) else { await queue.leave(); return }
        var code: String? = nil
        do {
            guard let conn = m.connection else { throw MailTransportError("no_connection", transient: false) }
            let secret = try await conn.credentialRef.asyncMap { try await secrets.secret(ref: $0) } ?? nil
            if conn.credentialRef != nil && secret == nil { throw MailTransportError("credential_missing", transient: false) }
            let transport: any MailTransport
            do { transport = try MailConnection.transport(kind: conn.kind, safeConfig: conn.safeConfig, secret: secret, allowedNets: allowedNets, allowInsecure: allowInsecure) }
            catch { throw MailTransportError("connection_invalid", transient: false) }
            // Queueing and secret resolution can suspend for a long time. Recheck both leases at the crossing point.
            guard await renewLease(m) else { await queue.leave(); return }
            if let beforeSend, try await !beforeSend() { await queue.leave(); return }
            struct Source: Decodable { let submission_id: Blob }
            let sql = db as! SQLDatabase
            guard let source = try await sql.raw("SELECT submission_id FROM mail_deliveries WHERE id=\(bind: DB.bin(m.deliveryID))").first(decoding: Source.self),
                  let submission = DB.uuid(source.submission_id.data),
                  try await recipientsAllowed(tx: sql, recipients: m.message.to + m.message.bcc, submission: submission) else { throw MailTransportError("recipient_not_allowed", transient: false) }
            try await transport.send(m.message)
        } catch let e as MailTransportError { code = e.code } catch { code = "internal" }
        await queue.leave()
        await finish(m, ok: code == nil, code: code)
    }

    static let sendLeaseSeconds: TimeInterval = 300

    func renewLease(_ m: PreparedMail) async -> Bool {
        struct N: Decodable { let n: Int }
        do {
            return try await (db as! SQLDatabase).withSession { s in
                try await s.raw("""
                    UPDATE mail_deliveries SET lease_until = \(bind: DB.time(now().addingTimeInterval(Self.sendLeaseSeconds))), updated_at = \(bind: DB.time(now()))
                    WHERE id = \(bind: DB.bin(m.deliveryID)) AND lease_token = \(bind: DB.bin(m.leaseToken)) AND state = 'leased'
                    """).run()
                return try await s.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n ?? 0 > 0
            }
        } catch { logger.warning("mail lease not renewed", metadata: ["type": "\(type(of: error))"]); return false }
    }

    /// Conditional on the lease token: a row that was meanwhile expired/claimed elsewhere is left alone.
    func finish(_ m: PreparedMail, ok: Bool, code: String?) async {
        do {
            try await (db as! SQLDatabase).raw("""
                UPDATE mail_deliveries SET state = \(bind: ok ? "smtp-accepted" : "waiting-manual"), attempts = attempts + 1, last_error_code = \(bind: ok ? nil : code),
                  lease_token = NULL, lease_until = NULL, fence = fence + 1, updated_at = \(bind: DB.time(now()))
                WHERE id = \(bind: DB.bin(m.deliveryID)) AND lease_token = \(bind: DB.bin(m.leaseToken)) AND state = 'leased'
                """).run()
            logger.info("mail delivery", metadata: ["id": "\(m.deliveryID.uuidString.lowercased())", "state": "\(ok ? "smtp-accepted" : "waiting-manual")", "code": "\(code ?? "-")"])
        } catch { logger.warning("mail delivery state not recorded", metadata: ["type": "\(type(of: error))"]) }
    }

    public static func allowedRecipients(_ recipients: [String], allowlist: [String]) -> Bool {
        let allowed = Set(allowlist.map { $0.lowercased() })
        return recipients.allSatisfy { allowed.contains($0.lowercased()) }
    }
    private func recipientsAllowed(tx: SQLDatabase, recipients: [String], submission: UUID) async throws -> Bool {
        struct Source: Decodable { let environment: String }
        guard let source = try await tx.raw("SELECT environment FROM submissions WHERE id=\(bind: DB.bin(submission))").first(decoding: Source.self) else { return false }
        let restricted = try await SystemSettings.value("mail.restricted", sql: tx)
        if source.environment != "test" && restricted != "true" { return true }
        let text = try await SystemSettings.value("mail.allowedRecipients", sql: tx)
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String] else { return false }
        return Self.allowedRecipients(recipients, allowlist: list)
    }

    /// Rows still leased after the lease ran out: the process died or hung after the hand-over, delivery is unknown.
    @discardableResult
    public static func expireLeases(db: Database, now: Date) async throws -> Int {
        struct N: Decodable { let n: Int }
        let sql = db as! SQLDatabase
        return try await sql.withSession { s in
            try await s.raw("UPDATE mail_deliveries SET state = 'uncertain', lease_token = NULL, lease_until = NULL, fence = fence + 1, last_error_code = 'lease_expired', updated_at = \(bind: DB.time(now)) WHERE state = 'leased' AND lease_until < \(bind: DB.time(now))").run()
            return try await s.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n ?? 0
        }
    }

    /// Bounded concurrency with a bounded backlog; beyond it a mail goes to `waiting-manual` (`busy`) instead of piling up in memory.
    actor SendQueue {
        let maxConcurrent: Int, maxQueued: Int
        private var running = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(maxConcurrent: Int, maxQueued: Int) { self.maxConcurrent = maxConcurrent; self.maxQueued = maxQueued }
        func enter() async -> Bool {
            if running < maxConcurrent { running += 1; return true }
            guard waiters.count < maxQueued else { return false }
            await withCheckedContinuation { waiters.append($0) }
            return true
        }
        func leave() { if let w = waiters.first { waiters.removeFirst(); w.resume() } else { running -= 1 } }
    }
}

private extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? { if let v = self { return try await f(v) }; return nil }
}

/// Marks deliveries whose lease ran out as `uncertain` (only one replica per round, like the auth maintenance).
public struct MailMaintenanceScheduler: LifecycleHandler {
    public static let lockName = "form_mail_maintenance"
    let interval: TimeInterval
    public init(interval: TimeInterval = 60) { self.interval = interval }

    /// One round; nil when another replica holds the lock.
    public static func runOnce(db: Database, now: Date) async throws -> Int? {
        struct L: Decodable { let l: Int? }
        return try await (db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(literal: lockName), 0) AS l").first(decoding: L.self)?.l == 1 else { return nil }
            do {
                let n = try await MailDispatcher.expireLeases(db: db, now: now)
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                return n
            } catch {
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                throw error
            }
        }
    }

    public func didBoot(_ app: Application) throws {
        let db = app.db(.mysql), logger = app.logger, interval = interval
        app.storage[MailSchedulerKey.self] = Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                do { if let n = try await Self.runOnce(db: db, now: Date()), n > 0 { logger.warning("mail deliveries with unknown outcome", metadata: ["count": "\(n)"]) } }
                catch { logger.warning("mail maintenance failed", metadata: ["type": "\(type(of: error))"]) }
            }
        }
    }
    public func shutdown(_ app: Application) { app.storage[MailSchedulerKey.self]?.cancel() }
}
private struct MailSchedulerKey: StorageKey { typealias Value = Task<Void, Never> }
