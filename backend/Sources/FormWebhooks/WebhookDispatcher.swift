// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Metadata-only webhook outbox. Expired leases are uncertain, never blindly sent again (ADR 0013).
public struct WebhookDispatcher: Sendable {
    public typealias Send = @Sendable (String, Data, String, String) async throws -> Int
    let db: Database
    let secrets: SecretStore
    let now: @Sendable () -> Date
    let send: Send
    public static let backoff = [60, 300, 900, 3600, 10800, 21600, 43200]
    public static let lockName = "form_webhooks"
    public init(db: Database, secrets: SecretStore, now: @escaping @Sendable () -> Date = { Date() },
                send: @escaping Send = { url, body, timestamp, signature in
                    try await WebhookHTTP().send(url: url, body: body, timestamp: timestamp, signature: signature)
                }) { self.db = db; self.secrets = secrets; self.now = now; self.send = send }

    public struct Claim: Decodable, Sendable {
        public let id: Blob, token: Blob
        public let fence: Int, attempts: Int
        public let customer_id: Blob, form_id: Blob, submission_id: Blob
        public let received_at: Date
        public let target_url: String, signing_secret_ref: String, public_key: Blob
    }

    /// Locks selection and changes ownership atomically. Only ready rows may be claimed, including by direct callers.
    public func claim(customer: Blob? = nil) async throws -> Claim? {
        // Sweep in a separate autocommit statement, without holding customer/endpoint locks.
        try await (db as! SQLDatabase).raw("""
            UPDATE webhook_outbox SET state = 'uncertain', last_error_code = 'lease-expired', lease_token = NULL, lease_until = NULL
            WHERE state = 'leased' AND lease_until <= \(bind: DB.time(now()))
            """).run()
        return try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct Customer: Decodable { let customer_id: Blob }
            let selectedCustomer: Blob?
            if let customer { selectedCustomer = customer }
            else {
                selectedCustomer = try await tx.raw("""
                    SELECT customer_id FROM webhook_outbox WHERE state = 'ready' AND attempts < 8
                      AND (next_attempt_at IS NULL OR next_attempt_at <= \(bind: DB.time(now())))
                    ORDER BY next_attempt_at, id LIMIT 1
                    """).first(decoding: Customer.self)?.customer_id
            }
            guard let selectedCustomer else { return nil }
            try await WebhookLimits.lockCustomer(tx, customer: selectedCustomer)
            let at = now()
            struct ID: Decodable { let id: Blob }
            guard let r = try await tx.raw("""
                SELECT w.id AS id FROM webhook_outbox w
                JOIN webhook_endpoints e ON e.customer_id = w.customer_id AND e.form_id = w.form_id AND e.id = w.webhook_id
                JOIN customers c ON c.id = w.customer_id
                WHERE w.state = 'ready' AND w.attempts < 8 AND (w.next_attempt_at IS NULL OR w.next_attempt_at <= \(bind: DB.time(at)))
                  AND e.active = 1 AND c.state = 'active' AND w.customer_id = \(bind: selectedCustomer)
                ORDER BY w.next_attempt_at, w.id LIMIT 1 FOR UPDATE
                """).first(decoding: ID.self) else { return nil }
            let token = DB.bin(UUID())
            try await tx.raw("""
                UPDATE webhook_outbox SET state = 'leased', lease_token = \(bind: token), lease_until = \(bind: DB.time(now().addingTimeInterval(30))),
                  fence = fence + 1, attempts = attempts + 1 WHERE id = \(bind: r.id) AND state = 'ready'
                """).run()
            return try await tx.raw("""
                SELECT w.id AS id, w.lease_token AS token, w.fence AS fence, w.attempts AS attempts,
                  w.customer_id AS customer_id, w.form_id AS form_id, w.submission_id AS submission_id, w.received_at AS received_at,
                  e.target_url AS target_url, e.signing_secret_ref AS signing_secret_ref, e.public_key AS public_key
                FROM webhook_outbox w JOIN webhook_endpoints e ON e.customer_id = w.customer_id AND e.form_id = w.form_id AND e.id = w.webhook_id
                WHERE w.id = \(bind: r.id)
                """).first(decoding: Claim.self)
        }
    }

    /// Fence, token and deadline must all still match. A stale worker cannot write a result over a newer owner.
    @discardableResult public func finish(_ claim: Claim, status: Int?, errorCode: String? = nil) async throws -> Bool {
        let success = status.map { (200..<300).contains($0) } ?? false
        let terminal = !success && claim.attempts >= 8
        let state = success ? "succeeded" : (terminal ? "failed-terminal" : "ready")
        let code: String? = success ? nil : (status.map { "http-\($0)" } ?? "transport-failed")
        return try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct R: Decodable { let id: Blob }
            // Acquire the row first: the clock used below must follow any lock wait.
            _ = try await tx.raw("SELECT id FROM webhook_outbox WHERE id = \(bind: claim.id) FOR UPDATE").first(decoding: R.self)
            let at = now()
            let next: String? = success || terminal ? nil : DB.time(at.addingTimeInterval(TimeInterval(Self.backoff[claim.attempts - 1])))
            try await tx.raw("""
                UPDATE webhook_outbox SET state = \(bind: state), next_attempt_at = \(bind: next),
                  completed_at = \(bind: success || terminal ? DB.time(at) : nil), last_error_code = \(bind: code), lease_token = NULL, lease_until = NULL
                WHERE id = \(bind: claim.id) AND state = 'leased' AND lease_token = \(bind: claim.token) AND fence = \(bind: claim.fence)
                  AND lease_until > \(bind: DB.time(at))
                """).run()
            struct N: Decodable { let n: Int }
            let updated = try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n == 1
            if !updated {
                try await tx.raw("""
                    UPDATE webhook_outbox SET state = 'uncertain', last_error_code = 'lease-expired', lease_token = NULL, lease_until = NULL
                    WHERE id = \(bind: claim.id) AND state = 'leased' AND lease_token = \(bind: claim.token) AND fence = \(bind: claim.fence)
                      AND lease_until <= \(bind: DB.time(now()))
                    """).run()
            }
            return updated
        }
    }

    public static func signingText(url: String, timestamp: String, body: Data) -> Data {
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return Data("KUBUS-WEBHOOK\nPOST\n\(url)\n\(timestamp)\n\(hash)".utf8)
    }

    public static func payload(_ c: Claim) throws -> Data {
        struct Payload: Encodable { let event = "anfrage.eingegangen"; let deliveryUUID, formularUUID, anfrageUUID, eingegangenAm: String }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Payload(deliveryUUID: DB.uuid(c.id.data)!.uuidString.lowercased(), formularUUID: DB.uuid(c.form_id.data)!.uuidString.lowercased(),
                                          anfrageUUID: DB.uuid(c.submission_id.data)!.uuidString.lowercased(), eingegangenAm: iso.string(from: c.received_at)))
    }

    /// Plan round-robin across customers, at most 20 rows per customer per pass.
    /// Claim only the next wave so no lease ages while waiting for a network slot.
    public func run(batch: Int = 100) async throws -> Int? {
        struct Customer: Decodable { let customer_id: Blob }
        let at = now()
        let plan = try await (db as! SQLDatabase).raw("""
            SELECT customer_id FROM (
              SELECT w.customer_id, w.next_attempt_at, w.id,
                ROW_NUMBER() OVER (PARTITION BY w.customer_id ORDER BY w.next_attempt_at, w.id) AS turn
              FROM webhook_outbox w
              JOIN webhook_endpoints e ON e.customer_id = w.customer_id AND e.form_id = w.form_id AND e.id = w.webhook_id
              JOIN customers c ON c.id = w.customer_id
              WHERE w.state = 'ready' AND w.attempts < 8 AND (w.next_attempt_at IS NULL OR w.next_attempt_at <= \(bind: DB.time(at)))
                AND e.active = 1 AND c.state = 'active'
            ) candidates WHERE turn <= 20 ORDER BY turn, next_attempt_at, id LIMIT \(bind: max(0, min(batch, 100)))
            """).all(decoding: Customer.self)
        var n = 0
        // Also sweep expired leases when no ready rows exist.
        if plan.isEmpty { _ = try await claimWave([]) }
        for start in stride(from: 0, to: plan.count, by: 8) {
            if Task.isCancelled { break }
            guard let claims = try await claimWave(Array(plan[start..<min(start + 8, plan.count)]).map(\.customer_id)) else { continue }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for c in claims { group.addTask { try await deliver(c) } }
                try await group.waitForAll()
            }
            n += claims.count
        }
        return n
    }

    private func claimWave(_ customers: [Blob]) async throws -> [Claim]? {
        struct L: Decodable { let l: Int? }
        return try await (db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(bind: Self.lockName), 0) AS l").first(decoding: L.self)?.l == 1 else { return nil }
            do {
                var claims: [Claim] = []
                if customers.isEmpty {
                    try await session.raw("""
                        UPDATE webhook_outbox SET state = 'uncertain', last_error_code = 'lease-expired', lease_token = NULL, lease_until = NULL
                        WHERE state = 'leased' AND lease_until <= \(bind: DB.time(now()))
                        """).run()
                }
                for customer in customers { if let c = try await claim(customer: customer) { claims.append(c) } }
                try await session.raw("SELECT RELEASE_LOCK(\(bind: Self.lockName))").run()
                return claims
            } catch {
                try? await session.raw("SELECT RELEASE_LOCK(\(bind: Self.lockName))").run()
                throw error
            }
        }
    }

    private func deliver(_ c: Claim) async throws {
        var status: Int?
        do {
            guard let seed = try await secrets.get(c.signing_secret_ref) else { throw Abort(.internalServerError) }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            guard key.publicKey.rawRepresentation == c.public_key.data else { throw Abort(.internalServerError) }
            let body = try Self.payload(c), ts = String(Int64(now().timeIntervalSince1970))
            let signature = try key.signature(for: Self.signingText(url: c.target_url, timestamp: ts, body: body)).base64EncodedString()
            struct R: Decodable { let c: Int }
            let valid = try await (db as! SQLDatabase).raw("""
                SELECT COUNT(*) AS c FROM webhook_outbox w JOIN webhook_endpoints e ON e.customer_id = w.customer_id AND e.form_id = w.form_id AND e.id = w.webhook_id
                JOIN customers customer ON customer.id = w.customer_id
                WHERE w.id = \(bind: c.id) AND w.state = 'leased' AND w.lease_token = \(bind: c.token) AND w.fence = \(bind: c.fence)
                  AND w.lease_until > \(bind: DB.time(now().addingTimeInterval(8))) AND e.active = 1 AND customer.state = 'active'
                """).first(decoding: R.self)?.c == 1
            if valid { status = try await send(c.target_url, body, ts, signature) }
        } catch { /* Persist only a fixed error category. */ }
        _ = try await finish(c, status: status)
    }

}

public struct WebhookScheduler: LifecycleHandler {
    let service: WebhookDispatcher
    public init(service: WebhookDispatcher) { self.service = service }
    public func didBoot(_ app: Application) throws {
        let service = service, logger = app.logger
        app.storage[WebhookTaskKey.self] = Task.detached {
            while !Task.isCancelled {
                do { _ = try await service.run() }
                catch { logger.warning("webhook cycle failed", metadata: ["type": "\(type(of: error))"]) }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }
    public func shutdown(_ app: Application) { app.storage[WebhookTaskKey.self]?.cancel() }
}
private struct WebhookTaskKey: StorageKey { typealias Value = Task<Void, Never> }
