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
    /// Token stored in `last_error_code` when the mail is accepted but incomplete (`attachments_omitted`); nil = complete.
    var warning: String? = nil
    /// Bytes of `resendMemory` this mail still holds (manual resend with attachments); released by `deliver`, whatever its outcome.
    public var heldMemory: Int = 0
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
    /// Origin of the PWA (FORM_ADMIN_ORIGIN) for the link in notification mails; nil = mail without link.
    let adminOrigin: String?
    /// Size limit of one whole mail with attachments (wire form), FORM_MAIL_MAX_BYTES; default 30 MiB.
    let maxMailBytes: Int
    /// Size limit of one whole mail (wire form); the resend route stops opening attachments beyond it.
    public var mailByteLimit: Int { maxMailBytes }
    /// Sends that carry attachments run at most `heavyConcurrent` at a time (each builds a ~1.4x copy of its attachments) and keep at most
    /// `heavyQueuedBytes` of attachment bytes waiting; beyond that the mail goes to `waiting-manual` (`busy`) instead of filling the 1024 MiB container.
    static let heavyConcurrent = 2, heavyQueuedBytes = 64 * 1024 * 1024
    /// Process-wide byte budget for resends that open stored attachments (ciphertext + wire text + plaintext copies exist at once).
    /// Reserved BEFORE the first byte is read from storage, so N parallel resends of large attachments cannot exhaust the heap;
    /// the route answers 503 + Retry-After when it is exhausted. Default: 4 x the mail size limit = one full-size resend at a time.
    public let resendMemory: MemoryBudget
    /// Transient copies of one attachment while it is read and decrypted (ciphertext, wire string, parsed package, plaintext).
    public static let resendCopyFactor = 4
    let heavy = AttachmentGate(maxConcurrent: MailDispatcher.heavyConcurrent, maxQueuedBytes: MailDispatcher.heavyQueuedBytes)

    public init(db: Database, secrets: any MailSecretProvider, allowedNets: [CIDR], allowInsecure: Bool, logger: Logger, adminOrigin: String? = nil, maxMailBytes: Int = MailMessage.defaultMaxWireBytes, now: @escaping @Sendable () -> Date = { Date() }, resendMemoryBytes: Int? = nil) {
        self.maxMailBytes = max(MailMessage.maxBytes, maxMailBytes); self.db = db; self.secrets = secrets; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.logger = logger; self.adminOrigin = adminOrigin; self.now = now
        queue = SendQueue(maxConcurrent: Self.maxConcurrent, maxQueued: Self.maxQueued)
        resendMemory = MemoryBudget(limit: resendMemoryBytes ?? Self.resendCopyFactor * self.maxMailBytes)
    }

    private struct ConnQuery: Decodable { let kind: String; let safe_config_json: String; let credential_ref: String?; let enabled: Int }

    /// Parses the plan of a form version definition (nil = no mail configured or invalid → nothing is sent).
    public static func plan(definition: [String: Any]) -> MailPlan? {
        guard let mail = definition["mail"] as? [String: Any] else { return nil }
        var names = Set<String>()
        for (_, f) in (definition["fields"] as? [String: Any]) ?? [:] { if let n = (f as? [String: Any])?["name"] as? String { names.insert(n) } }
        guard var plan = MailPlan.parse(mail, fieldNames: names).0 else { return nil }
        plan.formTitle = title(definition["title"])
        plan.fields = ((definition["fields"] as? [String: Any]) ?? [:]).keys.sorted { $0.compare($1, options: .numeric) == .orderedAscending }.compactMap { id in
            guard let f = (definition["fields"] as? [String: Any])?[id] as? [String: Any], let n = f["name"] as? String else { return nil }
            let label = title(f["label"]).unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : Character($0) }
            let text = String(label).trimmingCharacters(in: .whitespaces)
            return MailPlan.Field(name: n, label: text.isEmpty ? n : text)
        }
        return plan
    }

    /// `form.title` is localized (`{"de": "…"}`): German first, otherwise the first non-empty value by language key. A plain string is accepted as is.
    static func title(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        guard let map = raw as? [String: Any] else { return "" }
        if let de = map["de"] as? String, !de.isEmpty { return de }
        return map.keys.sorted().lazy.compactMap { map[$0] as? String }.first { !$0.isEmpty } ?? ""
    }

    /// When the submission came in (the "Zeitpunkt" of a notification); nil when unknown.
    private func receivedAt(_ tx: SQLDatabase, submission: UUID) async throws -> Date? {
        struct R: Decodable { let received_at: Date? }
        return try await tx.raw("SELECT received_at FROM submissions WHERE id=\(bind: DB.bin(submission))").first(decoding: R.self)?.received_at
    }

    /// Creates the delivery rows (inside `tx`) and renders the messages from the in-memory submission.
    /// `fields` are the submitted fields (`{"name": "value" | [..] | {..}}`).
    public func prepare(tx: SQLDatabase, plan: MailPlan, customer: Blob, form: Blob, submission: UUID, fields: [String: Any], identityScope: String = "form-mail", effectID: UUID? = nil, onlyKind: String? = nil, attachments: [MailAttachment]? = nil) async throws -> [PreparedMail] {
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

        func make(_ kind: String, to: [String], bcc: [String], replyTo: String?, template: MailPlan.Template, notify: Bool = false) async throws {
            let id = existingID ?? UUID()
            guard let conn else { try await row(kind: kind, state: "waiting-manual", code: "no_connection", token: nil, id: id); return }
            let received = kind == "organisation" ? try await receivedAt(tx, submission: submission) : nil
            do {
                let (rendered, shortened) = try MailTemplate.buildShorteningIfTooLarge(values: values) { v in
                    try Self.renderMessage(adminOrigin: adminOrigin, now: now(), receivedAt: received, plan: plan, to: to, bcc: bcc, replyTo: replyTo, template: template, notify: notify, isConfirmation: kind == "confirmation", values: v,
                                           customer: customer, form: form, submission: submission)
                }
                var msg = rendered
                if shortened { logger.warning("mail body shortened (message too large)", metadata: ["submission": "\(submission.uuidString.lowercased())", "kind": "\(kind)"]) }
                var warning: String? = nil
                if kind == "organisation" && !notify {
                    let unavailable = attachments == nil ? try await storedAttachmentCount(tx, submission: submission) : 0
                    warning = attach(to: &msg, attachments: attachments ?? [], unavailable: unavailable, maxCount: conn.kind == "mail-proxy" ? 1 : MailAttachment.maxPerMail)
                }
                guard try await recipientsAllowed(tx: tx, recipients: to + bcc, submission: submission) else {
                    try await row(kind: kind, state: "abandoned", code: "recipient_not_allowed", token: nil, id: id); return
                }
                try Self.validate(msg)   // size/format problems surface now, not at send time
                let token = UUID()
                try await row(kind: kind, state: "leased", code: nil, token: token, id: id)
                out.append(PreparedMail(deliveryID: id, leaseToken: token, message: msg, connection: conn, warning: warning))
            } catch let e as MailError {
                let code = e == .tooLarge ? "message_too_large" : "message_invalid"
                logger.warning("mail abandoned", metadata: ["submission": "\(submission.uuidString.lowercased())", "kind": "\(kind)", "code": "\(code)"])
                try await row(kind: kind, state: "abandoned", code: code, token: nil, id: id)
            }
        }

        if let o = plan.organisation, onlyKind == nil || onlyKind == "organisation" {
            let reply = o.replyToField.flatMap { values[$0] }.flatMap(MailAddress.parse)
            try await make("organisation", to: o.to, bcc: o.bcc, replyTo: reply, template: o.template, notify: o.content == .notification)
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
    public func prepareResend(tx: SQLDatabase, plan: MailPlan, customer: Blob, form: Blob, delivery: UUID, kind: String, allowUncertain: Bool, expectedFence: UInt64?, fields: [String: Any], attachments: [MailAttachment] = [], uploadedFileCount: Int = 0) async throws -> PreparedMail {
        var values = MailTemplate.values(fromFields: fields)
        plan.apply(derived: &values, now: now())
        guard let conn = try await connection(tx, customer: customer, form: form), ["smtp", "mail-proxy"].contains(conn.kind) else { throw ResendError.noConnection }
        let to: [String], bcc: [String], reply: String?, template: MailPlan.Template
        var notify = false
        switch kind {
        case "organisation":
            guard let o = plan.organisation else { throw ResendError.kindNotPlanned }
            to = o.to; bcc = o.bcc; reply = o.replyToField.flatMap { values[$0] }.flatMap(MailAddress.parse); template = o.template; notify = o.content == .notification
        case "confirmation":
            guard let c = plan.confirmation else { throw ResendError.kindNotPlanned }
            guard let addr = values[c.toField].flatMap(MailAddress.parse) else { throw ResendError.recipientInvalid }
            to = [addr]; bcc = []; reply = nil; template = c.template
        default: throw ResendError.kindNotPlanned
        }
        struct Submission: Decodable { let submission_id: Blob }
        guard let source = try await tx.raw("SELECT submission_id FROM mail_deliveries WHERE id=\(bind: DB.bin(delivery)) AND customer_id=\(bind: customer) AND form_id=\(bind: form)").first(decoding: Submission.self),
              let submission = DB.uuid(source.submission_id.data) else { throw ResendError.recipientInvalid }
        var message: MailMessage
        var warning: String? = nil
        let received = kind == "organisation" ? try await receivedAt(tx, submission: submission) : nil
        do {
            message = try Self.renderMessage(adminOrigin: adminOrigin, now: now(), receivedAt: received, plan: plan, to: to, bcc: bcc, replyTo: reply, template: template, notify: notify, isConfirmation: kind == "confirmation", values: values,
                                        customer: customer, form: form, submission: submission)
            // `attachments` = files the caller could open with the attachment keys the browser handed over (ADR 0049 Nachtrag, parity with ALT's AnfrageResend).
            // `uploadedFileCount` = files listed in the signed data (also counts objects that are gone). Files that are not among them (key or object missing, over the budget) are named as "not attached" and the row gets `attachments_omitted`.
            if kind == "organisation" && !notify {
                let stored = try await storedAttachmentCount(tx, submission: submission)
                warning = attach(to: &message, attachments: attachments, unavailable: max(0, max(stored, uploadedFileCount) - attachments.count), maxCount: conn.kind == "mail-proxy" ? 1 : MailAttachment.maxPerMail)
            }
            try Self.validate(message)
        } catch { throw ResendError.messageInvalid }
        guard try await recipientsAllowed(tx: tx, recipients: to + bcc, submission: submission) else { throw ResendError.recipientInvalid }
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
        return PreparedMail(deliveryID: delivery, leaseToken: token, message: message, connection: conn, warning: warning)
    }

    /// Text part and header checks without building the attachment parts (those are sized arithmetically by `MailAttachmentFit`).
    static func validate(_ msg: MailMessage) throws {
        var probe = msg; probe.attachments = []
        _ = try probe.rfc822()
    }

    /// Number of attachment objects stored for the submission whose bytes are NOT at hand (flow mail, manual resend).
    private func storedAttachmentCount(_ tx: SQLDatabase, submission: UUID) async throws -> Int {
        struct N: Decodable { let n: Int }
        return try await tx.raw("SELECT COUNT(*) AS n FROM stored_objects WHERE submission_id=\(bind: DB.bin(submission)) AND object_role='attachment' AND state='ready'").first(decoding: N.self)?.n ?? 0
    }

    /// Attaches what fits, names what does not (in the mail text) and returns the status token for the delivery row (nil = complete).
    /// `unavailable` = stored attachments whose bytes are not at hand: named only as a count, token as well.
    func attach(to msg: inout MailMessage, attachments: [MailAttachment], unavailable: Int, maxCount: Int) -> String? {
        guard !attachments.isEmpty || unavailable > 0 else { return nil }
        // reserve for the notice (names of left-out files) on top of the base64 text part
        let base = msg.body.utf8.count / 3 * 4 + 8192 + attachments.count * 400
        let fit = MailAttachmentFit(attachments, baseBytes: base, limit: maxMailBytes, maxCount: maxCount)
        if !fit.omitted.isEmpty || unavailable > 0 {
            msg.body += MailAttachmentNotice.render(omitted: fit.omitted, unavailable: unavailable, limit: maxMailBytes, html: msg.isHTML)
        }
        msg.attachments = fit.attached
        msg.maxWireBytes = maxMailBytes
        return fit.omitted.isEmpty && unavailable == 0 ? nil : "attachments_omitted"
    }

    /// Renders one message. `notify` (organisation mail in the explicitly chosen notification mode, ADR 0041) ignores the template and the submitted values completely;
    /// its "Zeitpunkt" is `receivedAt` (receipt of the submission, also on a later resend or a delayed flow mail), `now` only when unknown.
    static func renderMessage(adminOrigin: String?, now: Date, receivedAt: Date? = nil, plan: MailPlan, to: [String], bcc: [String], replyTo: String?, template: MailPlan.Template, notify: Bool, isConfirmation: Bool = false, values: [String: String],
                       customer: Blob, form: Blob, submission: UUID) throws -> MailMessage {
        if notify {
            let link = adminOrigin.flatMap { o in DB.uuid(customer.data).flatMap { c in DB.uuid(form.data).map { "\(o)/t/\(c.uuidString.lowercased())/f/\($0.uuidString.lowercased())/entries" } } }
            let n = MailNotification.render(formTitle: plan.formTitle, at: receivedAt ?? now, reference: submission.uuidString.lowercased(), link: link)
            return try MailMessage(fromAddress: plan.fromAddress, fromName: plan.fromName, to: to, bcc: bcc, replyTo: nil, subject: n.subject, body: n.body, isHTML: false, date: now)
        }
        // Organisation mail in `full` mode without its own subject/body (a new form, an import without template): the standard (decision 13.11.2026).
        let ownSubject = isConfirmation || !template.subject.trimmingCharacters(in: .whitespaces).isEmpty
        let ownBody = isConfirmation || !template.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let subject = ownSubject ? MailTemplate.renderSubject(template.subject, values: values) : MailStandard.subject(formTitle: plan.formTitle)
        let body = ownBody ? MailTemplate.render(template.body, values: values, html: template.isHTML)
            : MailStandard.body(formTitle: plan.formTitle, at: receivedAt ?? now, reference: submission.uuidString.lowercased(), fields: plan.fields, values: values)
        return try MailMessage(fromAddress: plan.fromAddress, fromName: plan.fromName, to: to, bcc: bcc, replyTo: replyTo, subject: subject, body: body, isHTML: ownBody && template.isHTML, date: now)
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
        await deliverReleasingMemory(m, beforeSend: beforeSend)
        if m.heldMemory > 0 { await resendMemory.release(m.heldMemory) }
    }

    private func deliverReleasingMemory(_ m: PreparedMail, beforeSend: (() async throws -> Bool)?) async {
        guard await queue.enter() else { await finish(m, ok: false, code: "busy"); return }
        // The lease started at `prepare`; waiting in the queue may have used it up (review M3). Renew it now, and only send while the row is
        // still ours: a row already turned `uncertain` must never be sent (a manual resend would then duplicate it).
        guard await renewLease(m) else { await queue.leave(); return }
        var code: String? = nil
        var heavyHeld = false
        do {
            guard let conn = m.connection else { throw MailTransportError("no_connection", transient: false) }
            let secret = try await conn.credentialRef.asyncMap { try await secrets.secret(ref: $0) } ?? nil
            if conn.credentialRef != nil && secret == nil { throw MailTransportError("credential_missing", transient: false) }
            let transport: any MailTransport
            do { transport = try MailConnection.transport(kind: conn.kind, safeConfig: conn.safeConfig, secret: secret, allowedNets: allowedNets, allowInsecure: allowInsecure) }
            catch { throw MailTransportError("connection_invalid", transient: false) }
            // Mails with attachments build a large wire copy: only a few at a time (never more waiting than the memory budget allows).
            let weight = m.message.attachments.reduce(0) { $0 + $1.data.count }
            if weight > 0 {
                guard await heavy.enter(weight) else { throw MailTransportError("busy", transient: true) }
                heavyHeld = true
            }
            // Queueing and secret resolution can suspend for a long time. Recheck both leases at the crossing point.
            guard await renewLease(m) else { if heavyHeld { await heavy.leave() }; await queue.leave(); return }
            if let beforeSend, try await !beforeSend() { if heavyHeld { await heavy.leave() }; await queue.leave(); return }
            struct Source: Decodable { let submission_id: Blob }
            let sql = db as! SQLDatabase
            guard let source = try await sql.raw("SELECT submission_id FROM mail_deliveries WHERE id=\(bind: DB.bin(m.deliveryID))").first(decoding: Source.self),
                  let submission = DB.uuid(source.submission_id.data),
                  try await recipientsAllowed(tx: sql, recipients: m.message.to + m.message.bcc, submission: submission) else { throw MailTransportError("recipient_not_allowed", transient: false) }
            try await transport.send(m.message)
        } catch let e as MailTransportError { code = e.code } catch { code = "internal" }
        if heavyHeld { await heavy.leave() }
        await queue.leave()
        await finish(m, ok: code == nil, code: code)
    }

    static let sendLeaseSeconds: TimeInterval = 300

    /// Extends the lease and reports whether the row is still ours (state `leased`, our token).
    /// Ownership is read back instead of derived from `ROW_COUNT()`: MariaDB reports *changed* rows, and `DB.time` has millisecond
    /// resolution, so a second renewal within the same millisecond writes identical values (0 rows) although the lease is intact.
    /// Counting that as "lost" silently dropped the delivery (row stuck `leased`, no mail, no log).
    func renewLease(_ m: PreparedMail) async -> Bool {
        struct N: Decodable { let n: Int }
        do {
            return try await (db as! SQLDatabase).withSession { s in
                try await s.raw("""
                    UPDATE mail_deliveries SET lease_until = \(bind: DB.time(now().addingTimeInterval(Self.sendLeaseSeconds))), updated_at = \(bind: DB.time(now()))
                    WHERE id = \(bind: DB.bin(m.deliveryID)) AND lease_token = \(bind: DB.bin(m.leaseToken)) AND state = 'leased'
                    """).run()
                return try await s.raw("""
                    SELECT COUNT(*) AS n FROM mail_deliveries
                    WHERE id = \(bind: DB.bin(m.deliveryID)) AND lease_token = \(bind: DB.bin(m.leaseToken)) AND state = 'leased'
                    """).first(decoding: N.self)?.n ?? 0 > 0
            }
        } catch { logger.warning("mail lease not renewed", metadata: ["type": "\(type(of: error))"]); return false }
    }

    /// Conditional on the lease token: a row that was meanwhile expired/claimed elsewhere is left alone.
    func finish(_ m: PreparedMail, ok: Bool, code: String?) async {
        do {
            try await (db as! SQLDatabase).raw("""
                UPDATE mail_deliveries SET state = \(bind: ok ? "smtp-accepted" : "waiting-manual"), attempts = attempts + 1, last_error_code = \(bind: ok ? m.warning : code),
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

    /// Bounds sends with attachments: `maxConcurrent` in flight, waiting ones limited by their attachment bytes.
    actor AttachmentGate {
        let maxConcurrent: Int, maxQueuedBytes: Int
        private var running = 0, queuedBytes = 0
        private var waiters: [(bytes: Int, c: CheckedContinuation<Void, Never>)] = []
        init(maxConcurrent: Int, maxQueuedBytes: Int) { self.maxConcurrent = maxConcurrent; self.maxQueuedBytes = maxQueuedBytes }
        func enter(_ bytes: Int) async -> Bool {
            if running < maxConcurrent { running += 1; return true }
            guard queuedBytes + bytes <= maxQueuedBytes else { return false }
            queuedBytes += bytes
            await withCheckedContinuation { waiters.append((bytes, $0)) }
            return true
        }
        func leave() { if let w = waiters.first { waiters.removeFirst(); queuedBytes -= w.bytes; w.c.resume() } else { running -= 1 } }
    }

    /// Non-blocking byte reservation: `tryReserve` fails instead of waiting, so callers answer 503 and never queue large buffers.
    public actor MemoryBudget {
        public nonisolated let limit: Int
        public private(set) var reserved = 0
        public init(limit: Int) { self.limit = limit }
        public func tryReserve(_ bytes: Int) -> Bool {
            guard bytes >= 0, bytes <= limit - reserved else { return false }
            reserved += bytes; return true
        }
        public func release(_ bytes: Int) { reserved = max(0, reserved - bytes) }
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
