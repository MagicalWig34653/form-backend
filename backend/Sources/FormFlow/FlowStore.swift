// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FluentMySQLDriver
import FormPersistence
import Foundation
import SQLKit

/// The ledger never stores fields or decryptable server keys. Ciphertext objects are supplied by the worker.
public struct FlowStore {
    public enum StoreError: Error { case invalidInput, staleLease, checkpointMissing, blocked, conflict }
    public struct Lease: Sendable {
        public let run: UUID
        public let customer: Blob
        public let form: Blob
        public let token: UUID
        public let fence: UInt64
        public let revision: UInt64
    }
    public struct EffectReservation: Sendable {
        public let id: UUID
        public let state: String
        public let isNew: Bool
    }
    public enum State: String { case running, waiting, waitingManual = "waiting-manual", complete, failed, cancelled }
    public let db: Database
    public init(db: Database) { self.db = db }
    private struct N: Decodable { let n: Int }
    private struct Run: Decodable {
        let customer_id: Blob; let form_id: Blob; let state: String; let fence: UInt64; let revision: UInt64
        let checkpoint_object_id: Blob; let checkpoint_json: String
    }
    private struct ObjectRow: Decodable { let ciphertext_sha256: Blob }
    private struct EffectRow: Decodable { let id: Blob; let state: String }

    /// Must be called in the submission transaction. The unique run slot is the ingest idempotency boundary.
    /// A ready handoff has a five-minute expiry so a crash before claim also becomes human-recoverable.
    @discardableResult
    public func create(tx: SQLDatabase, customer: Blob, form: Blob, submission: UUID, release: Blob,
                       checkpointObject: UUID, checkpointHash: Data, budgetJSON: String, digest: Data,
                       digestGeneration: Int64, deadline: Date, now: Date, runID: UUID = UUID()) async throws -> UUID {
        guard digest.count == 32, digestGeneration > 0, deadline > now,
              let budget = try JSONSerialization.jsonObject(with: Data(budgetJSON.utf8)) as? [String: Any],
              !budget.isEmpty, Self.numericBudget(budget) else { throw StoreError.invalidInput }
        try await verifyObject(tx, customer: customer, form: form, submission: submission, object: checkpointObject, hash: checkpointHash)
        let metadata = Self.metadata(checkpointHash)
        try await tx.raw("""
            INSERT INTO workflow_runs (id,customer_id,form_id,submission_id,release_id,run_slot,idempotency_key,
              request_digest,digest_key_generation,retain_until,state,continuation_policy,environment,checkpoint_object_id,
              checkpoint_json,budget_json,deadline_at,lease_token,lease_until)
            VALUES (\(bind: DB.bin(runID)),\(bind: customer),\(bind: form),\(bind: DB.bin(submission)),\(bind: release),'ingest','ingest',
              \(bind: Blob(digest)),\(bind: digestGeneration),\(bind: DB.time(deadline)),'ready','human-after-wait-or-crash','production',
              \(bind: DB.bin(checkpointObject)),\(bind: metadata),\(bind: budgetJSON),\(bind: DB.time(deadline)),\(bind: DB.bin(UUID())),\(bind: DB.time(now.addingTimeInterval(300))))
            """).run()
        return runID
    }

    /// Only a brand-new ready run may be claimed automatically. Expired running leases are never claimed.
    public func claim(run: UUID, now: Date, leaseSeconds: TimeInterval = 300) async throws -> Lease? {
        guard leaseSeconds > 0, leaseSeconds <= 300 else { throw StoreError.invalidInput }
        return try await db.transaction { database in
            let tx = database as! SQLDatabase
            guard let r = try await tx.raw("SELECT customer_id,form_id,state,fence,revision,checkpoint_object_id,checkpoint_json FROM workflow_runs WHERE id = \(bind: DB.bin(run)) FOR UPDATE").first(decoding: Run.self), r.state == "ready" else { return nil }
            let token = UUID()
            try await tx.raw("""
                UPDATE workflow_runs SET state='running',lease_token=\(bind: DB.bin(token)),lease_until=\(bind: DB.time(now.addingTimeInterval(leaseSeconds))),fence=fence+1,revision=revision+1
                WHERE id=\(bind: DB.bin(run)) AND state='ready' AND deadline_at > \(bind: DB.time(now)) AND lease_until > \(bind: DB.time(now))
                """).run()
            guard try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n == 1 else { return nil }
            return Lease(run: run, customer: r.customer_id, form: r.form_id, token: token, fence: r.fence + 1, revision: r.revision + 1)
        }
    }

    /// Serializes every checkpoint/effect operation with recovery and cancellation.
    public func assertLease(_ tx: SQLDatabase, lease: Lease, now: Date) async throws {
        guard try await tx.raw("""
            SELECT 1 AS n FROM workflow_runs WHERE id=\(bind: DB.bin(lease.run)) AND customer_id=\(bind: lease.customer) AND form_id=\(bind: lease.form)
              AND state='running' AND lease_token=\(bind: DB.bin(lease.token)) AND fence=\(bind: lease.fence)
              AND lease_until > \(bind: DB.time(now)) AND deadline_at > \(bind: DB.time(now)) FOR UPDATE
            """).first(decoding: N.self)?.n == 1 else { throw StoreError.staleLease }
    }

    public func checkpoint(lease: Lease, object: UUID, hash: Data, state: State, steps: UInt64, now: Date, wakeAt: Date? = nil, suspensionKind: String? = nil) async throws {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            try await assertLease(tx, lease: lease, now: now)
            try await checkpoint(tx: tx, lease: lease, object: object, hash: hash, state: state, steps: steps, now: now, wakeAt: wakeAt, suspensionKind: suspensionKind)
        }
    }

    /// Allows an encrypted object insert and checkpoint swap in the same transaction.
    public func checkpoint(tx: SQLDatabase, lease: Lease, object: UUID, hash: Data, state: State, steps: UInt64, now: Date, wakeAt: Date? = nil, suspensionKind: String? = nil) async throws {
        try await assertLease(tx, lease: lease, now: now)
        try await verifyObject(tx, customer: lease.customer, form: lease.form, submission: nil, object: object, hash: hash, run: lease.run)
        let retainLease = state == .running
        try await tx.raw("""
            UPDATE workflow_runs SET checkpoint_object_id=\(bind: DB.bin(object)),checkpoint_json=\(bind: Self.metadata(hash)),
              state=\(bind: state.rawValue),steps_used=\(bind: steps),revision=revision+1,
              wake_at=\(bind: wakeAt.map(DB.time)),suspension_json=\(bind: suspensionKind.map { "{\"kind\":\"" + $0 + "\"}" }),
              lease_token=\(bind: retainLease ? DB.bin(lease.token) : nil),lease_until=\(bind: retainLease ? DB.time(now.addingTimeInterval(300)) : nil)
            WHERE id=\(bind: DB.bin(lease.run)) AND lease_token=\(bind: DB.bin(lease.token)) AND fence=\(bind: lease.fence)
            """).run()
    }

    /// The reservation commits BEFORE handing off an external effect. Repeated prepared rows are reusable;
    /// in-flight/uncertain rows must never be handed off again without external reconciliation.
    public func reserveEffect(lease: Lease, node: String, visit: UInt64, slot: String, now: Date) async throws -> EffectReservation {
        try await db.transaction { database in
            try await reserveEffect(tx: database as! SQLDatabase, lease: lease, node: node, visit: visit, slot: slot, now: now)
        }
    }
    public func reserveEffect(tx: SQLDatabase, lease: Lease, node: String, visit: UInt64, slot: String, now: Date) async throws -> EffectReservation {
        guard !node.isEmpty, node.utf8.count <= 190, !slot.isEmpty, slot.utf8.count <= 64 else { throw StoreError.invalidInput }
        try await assertLease(tx, lease: lease, now: now)
        try await reconcileMail(tx, run: lease.run)
        if let old = try await tx.raw("SELECT id,state FROM workflow_effects WHERE run_id=\(bind: DB.bin(lease.run)) AND node_id=\(bind: node) AND visit_no=\(bind: visit) AND effect_slot=\(bind: slot) FOR UPDATE").first(decoding: EffectRow.self) {
            guard let id = DB.uuid(old.id.data) else { throw StoreError.invalidInput }
            return EffectReservation(id: id, state: old.state, isNew: false)
        }
        let id = UUID()
        try await tx.raw("""
            INSERT INTO workflow_effects (id,customer_id,form_id,run_id,node_id,visit_no,effect_slot,state,last_fence)
            VALUES (\(bind: DB.bin(id)),\(bind: lease.customer),\(bind: lease.form),\(bind: DB.bin(lease.run)),\(bind: node),\(bind: visit),\(bind: slot),'prepared',\(bind: lease.fence))
            """).run()
        return EffectReservation(id: id, state: "prepared", isNew: true)
    }

    /// Returns false when another invocation has already crossed the external-effect barrier.
    public func beginEffect(lease: Lease, effect: UUID, now: Date) async throws -> Bool {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            try await assertLease(tx, lease: lease, now: now)
            try await tx.raw("UPDATE workflow_effects SET state='in-flight',attempts=attempts+1,last_fence=\(bind: lease.fence) WHERE id=\(bind: DB.bin(effect)) AND run_id=\(bind: DB.bin(lease.run)) AND state='prepared'").run()
            return try await tx.raw("SELECT ROW_COUNT() AS n").first(decoding: N.self)?.n == 1
        }
    }
    public func finishEffect(lease: Lease, effect: UUID, confirmed: Bool, now: Date) async throws {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            try await assertLease(tx, lease: lease, now: now)
            try await tx.raw("UPDATE workflow_effects SET state=\(bind: confirmed ? "confirmed" : "uncertain") WHERE id=\(bind: DB.bin(effect)) AND run_id=\(bind: DB.bin(lease.run)) AND last_fence=\(bind: lease.fence) AND state='in-flight'").run()
        }
    }

    /// SMTP acceptance is durable evidence even when the worker lost its fence before ledger confirmation.
    public func reconcileMail(_ tx: SQLDatabase, run: UUID) async throws {
        try await tx.raw("""
            UPDATE workflow_effects e JOIN mail_deliveries d ON d.effect_id=e.id AND d.customer_id=e.customer_id AND d.form_id=e.form_id
            SET e.state='confirmed' WHERE e.run_id=\(bind: DB.bin(run)) AND e.state IN ('in-flight','uncertain') AND d.state='smtp-accepted'
            """).run()
    }

    /// Caller owns the run lock. Already started requests cannot be recalled.
    /// The outbox represents cancellation as failed-terminal; its ENUM has no cancelled state.
    public static func cancelReadyWebhooks(_ tx: SQLDatabase, run: UUID) async throws {
        try await tx.raw("""
            UPDATE webhook_outbox o JOIN workflow_effects e ON e.id=o.effect_id
            SET o.state='failed-terminal',o.last_error_code='flow-stopped',o.next_attempt_at=NULL,o.completed_at=NOW(6)
            WHERE e.run_id=\(bind: DB.bin(run)) AND o.state='ready'
            """).run()
    }

    /// Expiry never starts a worker. A timeout rejection still needs a human resume and encrypted proofs.
    public func expireWaiting(now: Date) async throws {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            struct Due: Decodable { let id: Blob; let customer_id: Blob; let form_id: Blob; let release_id: Blob; let deadline_at: Date; let steps_used: UInt64 }
            let rows = try await tx.raw("""
                SELECT id,customer_id,form_id,release_id,deadline_at,steps_used FROM workflow_runs r
                WHERE r.state IN ('ready','running','waiting','waiting-manual','paused','uncertain') AND
                  (r.deadline_at <= \(bind: DB.time(now)) OR EXISTS (SELECT 1 FROM workflow_approvals a WHERE a.run_id=r.id AND a.state='pending' AND a.expires_at <= \(bind: DB.time(now)))) FOR UPDATE
                """).all(decoding: Due.self)
            for row in rows {
                guard let run = DB.uuid(row.id.data) else { throw StoreError.invalidInput }
                var failed = row.deadline_at <= now
                struct Approval: Decodable { let id: Blob; let node_id: String }
                let approvals = try await tx.raw("SELECT id,node_id FROM workflow_approvals WHERE run_id=\(bind: row.id) AND state='pending' AND expires_at <= \(bind: DB.time(now)) FOR UPDATE").all(decoding: Approval.self)
                for approval in approvals {
                    if !failed {
                        let definition = try await FlowEngine.definition(sql: tx, customer: row.customer_id, form: row.form_id, release: row.release_id)
                        if definition?.nodes[approval.node_id]?.flowObject?["onTimeout"] != .string("reject") { failed = true }
                    }
                    try await tx.raw("UPDATE workflow_approvals SET state='expired' WHERE id=\(bind: approval.id)").run()
                }
                try await tx.raw("UPDATE workflow_effects SET state='uncertain' WHERE run_id=\(bind: row.id) AND state='in-flight'").run()
                try await reconcileMail(tx, run: run)
                if failed { try await Self.cancelReadyWebhooks(tx, run: run) }
                try await tx.raw("""
                    UPDATE workflow_runs SET state=\(bind: failed ? "failed" : "waiting-manual"),suspension_json=\(bind: failed ? "{\"kind\":\"timeout\"}" : "{\"kind\":\"approval-timeout\"}"),
                      lease_token=NULL,lease_until=NULL,fence=fence+1,revision=revision+1 WHERE id=\(bind: row.id)
                    """).run()
            }
        }
    }

    public func approval(lease: Lease, node: String, visit: UInt64, expires: Date, now: Date) async throws -> UUID {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            try await assertLease(tx, lease: lease, now: now)
            struct A: Decodable { let id: Blob }
            if let row = try await tx.raw("SELECT id FROM workflow_approvals WHERE run_id=\(bind: DB.bin(lease.run)) AND node_id=\(bind: node) AND visit_no=\(bind: visit)").first(decoding: A.self), let id = DB.uuid(row.id.data) { return id }
            let id = UUID()
            try await tx.raw("""
                INSERT INTO workflow_approvals (id,customer_id,form_id,run_id,node_id,visit_no,state,expires_at)
                VALUES (\(bind: DB.bin(id)),\(bind: lease.customer),\(bind: lease.form),\(bind: DB.bin(lease.run)),\(bind: node),\(bind: visit),'pending',\(bind: DB.time(expires)))
                """).run()
            return id
        }
    }

    /// No worker restart, even for plaintext-free runs: crash always requires a new human resumption.
    @discardableResult
    public func recoverExpired(now: Date) async throws -> Int {
        try await db.transaction { database in
            let tx = database as! SQLDatabase
            struct ID: Decodable { let id: Blob }
            let rows = try await tx.raw("SELECT id FROM workflow_runs WHERE state IN ('ready','running') AND lease_until <= \(bind: DB.time(now)) FOR UPDATE").all(decoding: ID.self)
            for r in rows {
                try await tx.raw("UPDATE workflow_effects SET state='uncertain' WHERE run_id=\(bind: r.id) AND state='in-flight'").run()
                try await tx.raw("""
                    UPDATE workflow_runs SET state='waiting-manual',suspension_json='{"kind":"crash-recovery"}',lease_token=NULL,lease_until=NULL,fence=fence+1,revision=revision+1 WHERE id=\(bind: r.id)
                    """).run()
            }
            return rows.count
        }
    }

    public struct Snapshot: Decodable {
        public let state: String
        public let revision: UInt64
        public let checkpoint_object_id: Blob
        public let checkpoint_json: String
        public let budget_json: String
        public let steps_used: UInt64
    }
    public func snapshot(run: UUID, customer: Blob, form: Blob) async throws -> Snapshot? {
        try await (db as! SQLDatabase).raw("SELECT state,revision,checkpoint_object_id,checkpoint_json,budget_json,steps_used FROM workflow_runs WHERE id=\(bind: DB.bin(run)) AND customer_id=\(bind: customer) AND form_id=\(bind: form)").first(decoding: Snapshot.self)
    }

    /// The route must validate CSRF, fresh human authentication and originalProof before calling this.
    /// authorizeAndVerify runs under the run lock on the SAME transaction and must recheck current scoped
    /// rights, exact checkpoint/original object proofs, release compatibility, gates and budgets.
    /// No queued continuation is created: the resulting lease belongs to the immediate in-memory worker.
    public func resume(run: UUID, customer: Blob, form: Blob, session: UUID, actor: UUID,
                       expectedRevision: UInt64, checkpointHash: Data, now: Date,
                       authorizeAndVerify: @escaping (SQLDatabase) async throws -> Void) async throws -> Lease {
        guard checkpointHash.count == 32 else { throw StoreError.invalidInput }
        return try await db.transaction { database in
            let tx = database as! SQLDatabase
            guard let r = try await tx.raw("SELECT customer_id,form_id,state,fence,revision,checkpoint_object_id,checkpoint_json FROM workflow_runs WHERE id=\(bind: DB.bin(run)) AND customer_id=\(bind: customer) AND form_id=\(bind: form) AND deadline_at > \(bind: DB.time(now)) AND (wake_at IS NULL OR wake_at <= \(bind: DB.time(now))) FOR UPDATE").first(decoding: Run.self),
                  ["waiting", "waiting-manual"].contains(r.state), r.revision == expectedRevision,
                  let object = DB.uuid(r.checkpoint_object_id.data) else { throw StoreError.conflict }
            try await verifyObject(tx, customer: customer, form: form, submission: nil, object: object, hash: checkpointHash, run: run)
            guard try await tx.raw("""
                SELECT 1 AS n FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.id=\(bind: DB.bin(session)) AND s.account_id=\(bind: DB.bin(actor))
                  AND s.state='authenticated' AND a.active=1 AND s.rights_version=a.rights_version
                  AND s.idle_expires_at > \(bind: DB.time(now)) AND s.absolute_expires_at > \(bind: DB.time(now)) FOR UPDATE
                """).first(decoding: N.self)?.n == 1 else { throw StoreError.blocked }
            try await authorizeAndVerify(tx)
            try await reconcileMail(tx, run: run)
            guard try await tx.raw("SELECT COUNT(*) AS n FROM workflow_approvals a JOIN workflow_runs r ON r.id=a.run_id WHERE a.run_id=\(bind: DB.bin(run)) AND r.steps_used > 0 AND a.visit_no=r.steps_used-1 AND a.state NOT IN ('approved','rejected','expired')").first(decoding: N.self)?.n == 0,
                  try await tx.raw("SELECT COUNT(*) AS n FROM workflow_effects WHERE run_id=\(bind: DB.bin(run)) AND state IN ('in-flight','uncertain')").first(decoding: N.self)?.n == 0 else { throw StoreError.blocked }
            let token = UUID(), stamp = DB.time(now)
            try await tx.raw("""
                INSERT INTO workflow_resumptions (id,customer_id,form_id,run_id,expected_revision,checkpoint_sha256,session_id,confirmed_by,confirmed_at,consumed_at)
                VALUES (\(bind: DB.bin(UUID())),\(bind: customer),\(bind: form),\(bind: DB.bin(run)),\(bind: expectedRevision),\(bind: Blob(checkpointHash)),\(bind: DB.bin(session)),\(bind: DB.bin(actor)),\(bind: stamp),\(bind: stamp))
                """).run()
            try await tx.raw("UPDATE workflow_runs SET state='running',suspension_json=NULL,lease_token=\(bind: DB.bin(token)),lease_until=\(bind: DB.time(now.addingTimeInterval(300))),fence=fence+1,revision=revision+1 WHERE id=\(bind: DB.bin(run))").run()
            return Lease(run: run, customer: customer, form: form, token: token, fence: r.fence + 1, revision: r.revision + 1)
        }
    }

    private func verifyObject(_ tx: SQLDatabase, customer: Blob, form: Blob, submission: UUID?, object: UUID, hash: Data, run: UUID? = nil) async throws {
        guard hash.count == 32 else { throw StoreError.invalidInput }
        let row: ObjectRow?
        if let submission {
            row = try await tx.raw("SELECT ciphertext_sha256 FROM stored_objects WHERE id=\(bind: DB.bin(object)) AND customer_id=\(bind: customer) AND form_id=\(bind: form) AND submission_id=\(bind: DB.bin(submission)) AND object_role='checkpoint' AND state='ready' AND packet_format='KUBUS-AEAD:2'").first(decoding: ObjectRow.self)
        } else if let run {
            row = try await tx.raw("SELECT o.ciphertext_sha256 FROM stored_objects o JOIN workflow_runs r ON r.submission_id=o.submission_id AND r.customer_id=o.customer_id AND r.form_id=o.form_id WHERE r.id=\(bind: DB.bin(run)) AND o.id=\(bind: DB.bin(object)) AND o.customer_id=\(bind: customer) AND o.form_id=\(bind: form) AND o.object_role='checkpoint' AND o.state='ready' AND o.packet_format='KUBUS-AEAD:2'").first(decoding: ObjectRow.self)
        } else { throw StoreError.checkpointMissing }
        guard row?.ciphertext_sha256.data == hash else { throw StoreError.checkpointMissing }
    }
    private static func numericBudget(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            return !object.isEmpty && object.values.allSatisfy { numericBudget($0) }
        }
        guard let number = value as? NSNumber else { return false }
        return number.doubleValue.isFinite && number.doubleValue >= 0
    }
    private static func metadata(_ hash: Data) -> String { "{\"sha256\":\"" + hash.map { String(format: "%02x", $0) }.joined() + "\"}" }
}
