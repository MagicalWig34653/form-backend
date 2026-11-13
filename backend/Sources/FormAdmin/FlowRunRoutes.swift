// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormCrypto
import FormFlow
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Human-only run controls. Approval never starts a worker; resume consumes its own revision-bound evidence.
enum FlowRunRoutes {
    typealias ResumeHandler = @Sendable (FlowStore.Lease, FlowState) async throws -> Void
    struct Run: Decodable {
        let id: Blob; let submission_id: Blob; let release_id: Blob; let state: String; let revision: UInt64
        let checkpoint_object_id: Blob; let checkpoint_json: String; let deadline_at: Date; let wake_at: Date?
        let budget_json: String; let steps_used: UInt64; let active_time_ms: UInt64
    }
    struct Object: Decodable {
        let id: Blob; let object_role: String; let revision: UInt64; let ciphertext: Blob?
        let ciphertext_sha256: Blob; let payload_sha256: Blob?; let kid: String; let state: String
        let ordinal_no: UInt64; let generation_id: Blob?; let wrap_kind: String; let byte_count: UInt64
    }
    struct Revision: Decodable { let expectedRevision: UInt64 }
    struct ApprovalInput: Decodable { let expectedRevision: UInt64; let decision: String }
    struct Proof: Decodable { let objectId: String; let expectedRevision: UInt64; let expectedSha256: String; let cek: String }
    struct OriginalProof: Decodable { let objects: [Proof] }
    struct ResumeInput: Decodable { let expectedRevision: UInt64; let checkpointHash: String; let originalProof: OriginalProof }
    private struct N: Decodable { let n: Int }
    struct Approval: Decodable { let node_id: String; let visit_no: UInt64; let state: String; let expires_at: Date }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService,
                         now: @escaping @Sendable () -> Date, resume: ResumeHandler? = nil) {
        let sql = db as! SQLDatabase
        let runs = tenants.grouped("forms", ":formId", "runs", ":runId")
        runs.get { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let r = try await load(sql, tenant: tenant, form: form, id: id)
            try await perms.authorize(account: s.accountID!, "flow.resume", on: .form(customer: tenant, form: form), exists: r != nil)
            return try noStore(FormAdmin.json(.ok, RunBody(id: lower(id), state: r!.state, revision: r!.revision)))
        }
        runs.post("cancel") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let b: Revision = try FormAdmin.decodeStrict(req, allowed: ["expectedRevision"])
            try await db.transaction { database in
                let tx = database as! SQLDatabase
                let r = try await load(tx, tenant: tenant, form: form, id: id, lock: true)
                try await PermissionService(sql: tx).authorize(account: s.accountID!, "flow.execute", on: .form(customer: tenant, form: form), exists: r != nil)
                _ = try await ReleaseRoutes.freshAuthentication(tx, session: s.id, now: now())
                guard let r, r.revision == b.expectedRevision, !["complete", "failed", "cancelled"].contains(r.state) else { throw Abort(.conflict) }
                try await tx.raw("UPDATE workflow_effects SET state='uncertain' WHERE run_id=\(bind: DB.bin(id)) AND state='in-flight'").run()
                try await FlowStore.cancelReadyWebhooks(tx, run: id)
                try await tx.raw("UPDATE workflow_runs SET state='cancelled',lease_token=NULL,lease_until=NULL,fence=fence+1,revision=revision+1 WHERE id=\(bind: DB.bin(id))").run()
                try await audit(tx, tenant: tenant, form: form, account: s.accountID!, run: id, action: "flow.cancel", at: now())
            }
            return try noStore(FormAdmin.json(.ok, RunBody(id: lower(id), state: "cancelled", revision: b.expectedRevision + 1)))
        }
        runs.post("approve") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let b: ApprovalInput = try FormAdmin.decodeStrict(req, allowed: ["expectedRevision", "decision"])
            guard ["approved", "rejected"].contains(b.decision) else { throw Abort(.unprocessableEntity) }
            try await db.transaction { database in
                let tx = database as! SQLDatabase
                let r = try await load(tx, tenant: tenant, form: form, id: id, lock: true)
                try await PermissionService(sql: tx).authorize(account: s.accountID!, "flow.approve", on: .form(customer: tenant, form: form), exists: r != nil)
                _ = try await ReleaseRoutes.freshAuthentication(tx, session: s.id, now: now())
                guard let r, r.revision == b.expectedRevision, ["waiting", "waiting-manual"].contains(r.state) else { throw Abort(.conflict) }
                struct A: Decodable { let id: Blob }
                let pending = try await tx.raw("SELECT id FROM workflow_approvals WHERE run_id=\(bind: DB.bin(id)) AND visit_no=\(bind: r.steps_used > 0 ? r.steps_used - 1 : UInt64.max) AND state='pending' AND expires_at > \(bind: DB.time(now())) FOR UPDATE").all(decoding: A.self)
                guard pending.count == 1 else { throw Abort(.conflict) }
                try await tx.raw("UPDATE workflow_approvals SET state=\(bind: b.decision),answered_by=\(bind: DB.bin(s.accountID!)),answered_at=\(bind: DB.time(now())) WHERE id=\(bind: pending[0].id)").run()
                try await tx.raw("UPDATE workflow_runs SET revision=revision+1 WHERE id=\(bind: DB.bin(id))").run()
                try await audit(tx, tenant: tenant, form: form, account: s.accountID!, run: id, action: "flow.approve", at: now())
            }
            return try noStore(FormAdmin.json(.ok, RunBody(id: lower(id), state: b.decision, revision: b.expectedRevision + 1)))
        }
        runs.get("resume-context") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let r = try await load(sql, tenant: tenant, form: form, id: id)
            try await perms.authorize(account: s.accountID!, "flow.resume", on: .form(customer: tenant, form: form), exists: r != nil)
            let run = r!, objects = try await requiredObjects(sql, tenant: tenant, form: form, run: run)
            var blocked = [String]()
            let approvals = try await currentApprovals(sql, run: id, steps: Int(exactly: run.steps_used) ?? -1)
            if approvals.count > 1 || approvals.contains(where: { !["approved", "rejected", "expired"].contains($0.state) }) { blocked.append("gate-open") }
            if approvals.contains(where: { $0.state == "expired" }) {
                let definition = try await FlowEngine.definition(sql: sql, customer: DB.bin(tenant), form: DB.bin(form), release: run.release_id)
                if approvals.contains(where: { $0.state == "expired" && definition?.nodes[$0.node_id]?.object?["onTimeout"] != .string("reject") }) { blocked.append("gate-open") }
            }
            if try await needsManifest(sql, tenant: tenant, form: form, run: run), !objects.contains(where: { $0.object_role == "mail-manifest" }) { blocked.append("manifest-missing") }
            if !["waiting", "waiting-manual"].contains(run.state) || run.deadline_at <= now() || run.wake_at.map({ $0 > now() }) == true { blocked.append("gate-open") }
            if objects.first(where: { $0.id == run.checkpoint_object_id }) == nil { blocked.append("object-missing") }
            var items = [ObjectBody]()
            for object in objects {
                var access = "allowed"
                if object.id != run.checkpoint_object_id {
                    do {
                        try await perms.authorize(account: s.accountID!, "content.read", on: .form(customer: tenant, form: form))
                        try await perms.authorize(account: s.accountID!, "content.decrypt", on: .form(customer: tenant, form: form))
                    } catch { access = "denied"; blocked.append("object-denied") }
                }
                if object.state != "ready" { blocked.append("object-missing") }
                items.append(try objectBody(object, access: access))
            }
            guard let checkpoint = items.first(where: { $0.objectId == DB.uuid(run.checkpoint_object_id.data).map(lower) }) else { throw Abort(.conflict) }
            return try noStore(FormAdmin.json(.ok, ContextBody(runId: lower(id), state: run.state, revision: run.revision, checkpointHash: checkpointHash(run),
                checkpoint: checkpoint, manifestObjectId: items.first(where: { $0.role == "mail-manifest" })?.objectId, requiredObjects: items, blocked: Array(Set(blocked)).sorted())))
        }
        runs.get("checkpoint", "ciphertext") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let r = try await load(sql, tenant: tenant, form: form, id: id)
            try await perms.authorize(account: s.accountID!, "flow.resume", on: .form(customer: tenant, form: form), exists: r != nil)
            _ = try await ReleaseRoutes.freshAuthentication(sql, session: s.id, now: now())
            guard let o = try await requiredObjects(sql, tenant: tenant, form: form, run: r!).first(where: { $0.id == r!.checkpoint_object_id }),
                  o.state == "ready", let wire = o.ciphertext else { throw Abort(.conflict) }
            try await audit(sql, tenant: tenant, form: form, account: s.accountID!, run: id, action: "flow.checkpoint.read", at: now())
            return try noStore(FormAdmin.json(.ok, CipherBody(object: try objectBody(o, access: "allowed"), package: String(decoding: wire.data, as: UTF8.self))))
        }
        runs.post("resume") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let (tenant, form, id) = try ids(req)
            let b: ResumeInput = try FormAdmin.decodeStrict(req, allowed: ["expectedRevision", "checkpointHash", "originalProof"])
            try strictProofShape(req)
            let r = try await load(sql, tenant: tenant, form: form, id: id)
            try await perms.authorize(account: s.accountID!, "flow.resume", on: .form(customer: tenant, form: form), exists: r != nil)
            _ = try await ReleaseRoutes.freshAuthentication(sql, session: s.id, now: now())
            // No callback means this deployment has no worker. Never consume a human approval in that case.
            guard let resume else { throw Abort(.conflict) }
            var state: FlowState?
            guard let digest = decodeHex(b.checkpointHash) else { throw Abort(.badRequest) }
            let lease: FlowStore.Lease
            do { lease = try await FlowStore(db: db).resume(run: id, customer: DB.bin(tenant), form: DB.bin(form),
                session: s.id, actor: s.accountID!, expectedRevision: b.expectedRevision, checkpointHash: digest, now: now()) { tx in
                try await PermissionService(sql: tx).authorize(account: s.accountID!, "flow.resume", on: .form(customer: tenant, form: form))
                _ = try await ReleaseRoutes.freshAuthentication(tx, session: s.id, now: now())
                guard let run = try await load(tx, tenant: tenant, form: form, id: id) else { throw Abort(.notFound) }
                let objects = try await requiredObjects(tx, tenant: tenant, form: form, run: run, lock: true)
                if objects.contains(where: { $0.id != run.checkpoint_object_id }) {
                    try await PermissionService(sql: tx).authorize(account: s.accountID!, "content.read", on: .form(customer: tenant, form: form))
                    try await PermissionService(sql: tx).authorize(account: s.accountID!, "content.decrypt", on: .form(customer: tenant, form: form))
                }
                if try await needsManifest(tx, tenant: tenant, form: form, run: run), !objects.contains(where: { $0.object_role == "mail-manifest" }) { throw Abort(.conflict) }
                let opened = try validateProof(b.originalProof, objects: objects, checkpoint: run.checkpoint_object_id)
                guard opened.steps >= 0, UInt64(opened.steps) == run.steps_used,
                      let budgets = (try? JSONSerialization.jsonObject(with: Data(run.budget_json.utf8))) as? [String: Any],
                      let maxSteps = budgets["maxSteps"] as? NSNumber, run.steps_used < maxSteps.uint64Value else { throw Abort(.conflict) }
                if let maxActive = budgets["activeTimeoutMs"] as? NSNumber, run.active_time_ms >= maxActive.uint64Value { throw Abort(.conflict) }
                let approvals = try await currentApprovals(tx, run: id, steps: opened.steps, lock: true)
                guard approvals.count <= 1 else { throw Abort(.conflict) }
                if let approval = approvals.first {
                    guard let definition = try await FlowEngine.definition(sql: tx, customer: DB.bin(tenant), form: DB.bin(form), release: run.release_id) else { throw Abort(.conflict) }
                    state = try applyApproval(opened, definition: definition, approval: approval, now: now())
                } else { state = opened }
                try await audit(tx, tenant: tenant, form: form, account: s.accountID!, run: id, action: "flow.resume", at: now())
            }
            } catch is FlowStore.StoreError { throw Abort(.conflict) } catch is FlowError { throw Abort(.conflict) }
            guard let state else { throw Abort(.conflict) }
            try await resume(lease, state)
            guard let finished = try await load(sql, tenant: tenant, form: form, id: id) else { throw Abort(.notFound) }
            return try noStore(FormAdmin.json(.ok, RunBody(id: lower(id), state: finished.state, revision: finished.revision)))
        }
    }

    /// A stored approval checkpoint points at its default approved port. The human decision chooses the port
    /// only for this exact node visit; previous approvals do not constrain later waits or recovery checkpoints.
    static func applyApproval(_ state: FlowState, definition: FlowDefinition, approval: Approval, now: Date) throws -> FlowState {
        guard state.steps > 0, approval.visit_no == UInt64(state.steps - 1) else { return state }
        let timedOut = approval.state == "expired" || (approval.state == "pending" && approval.expires_at <= now)
        let decision = timedOut && definition.nodes[approval.node_id]?.object?["onTimeout"] == .string("reject") ? "rejected" : approval.state
        guard ["approved", "rejected"].contains(decision),
              definition.nodes[approval.node_id]?.object?["kind"] == .string("approval"),
              let ports = definition.edges[approval.node_id], let approved = ports["approved"], let target = ports[decision],
              state.nodeID == approved || state.nodeID == target else { throw Abort(.conflict) }
        var next = state; next.nodeID = target; return next
    }
    static func currentApprovals(_ sql: SQLDatabase, run: UUID, steps: Int, lock: Bool = false) async throws -> [Approval] {
        guard steps > 0 else { return [] }
        return try await sql.raw("SELECT node_id,visit_no,state,expires_at FROM workflow_approvals WHERE run_id=\(bind: DB.bin(run)) AND visit_no=\(bind: UInt64(steps - 1)) \(unsafeRaw: lock ? "FOR UPDATE" : "")").all(decoding: Approval.self)
    }
    static func validateProof(_ proof: OriginalProof, objects: [Object], checkpoint: Blob) throws -> FlowState {
        guard proof.objects.count == objects.count, Set(proof.objects.map(\.objectId)).count == proof.objects.count,
              Set(proof.objects.compactMap { UUID(uuidString: $0.objectId).map { hex(DB.bin($0).data) } }) == Set(objects.map { hex($0.id.data) }) else { throw Abort(.conflict) }
        var state: FlowState?
        for object in objects {
            guard let p = proof.objects.first(where: { UUID(uuidString: $0.objectId).map(DB.bin) == object.id }),
                  p.expectedRevision == object.revision, p.expectedSha256 == hex(object.ciphertext_sha256.data),
                  object.state == "ready", let wire = object.ciphertext?.data,
                  Data(SHA256.hash(data: wire)) == object.ciphertext_sha256.data,
                  let cek = Data(base64Encoded: p.cek), cek.count == 32, cek.base64EncodedString() == p.cek,
                  let packet = try? PackageV2(String(decoding: wire, as: UTF8.self)),
                  let plain = try? packet.open(withCEK: cek) else { throw Abort(.conflict) }
            if let digest = object.payload_sha256, Data(SHA256.hash(data: packet.iv + packet.ciphertext + packet.tag)) != digest.data { throw Abort(.conflict) }
            if object.id == checkpoint { state = try FlowState(json: JCS.parse(plain)) }
        }
        guard let state else { throw Abort(.conflict) }
        return state
    }
    static func load(_ sql: SQLDatabase, tenant: UUID, form: UUID, id: UUID, lock: Bool = false) async throws -> Run? {
        try await sql.raw("SELECT id,submission_id,release_id,state,revision,checkpoint_object_id,checkpoint_json,deadline_at,wake_at,budget_json,steps_used,active_time_ms FROM workflow_runs WHERE id=\(bind: DB.bin(id)) AND customer_id=\(bind: DB.bin(tenant)) AND form_id=\(bind: DB.bin(form)) \(unsafeRaw: lock ? "FOR UPDATE" : "")").first(decoding: Run.self)
    }
    static func requiredObjects(_ sql: SQLDatabase, tenant: UUID, form: UUID, run: Run, lock: Bool = false) async throws -> [Object] {
        try await sql.raw("SELECT o.id,o.object_role,o.revision,o.ciphertext,o.ciphertext_sha256,o.payload_sha256,o.kid,o.state,o.ordinal_no,g.generation_id,o.wrap_kind,o.byte_count FROM stored_objects o LEFT JOIN customer_key_generations g ON g.customer_id=o.customer_id AND g.kid=o.kid WHERE o.customer_id=\(bind: DB.bin(tenant)) AND o.form_id=\(bind: DB.bin(form)) AND o.submission_id=\(bind: run.submission_id) AND (o.id=\(bind: run.checkpoint_object_id) OR o.object_role IN ('data','attachment','mail-organisation','mail-filler','mail-manifest')) ORDER BY o.id \(unsafeRaw: lock ? "FOR UPDATE" : "")").all(decoding: Object.self)
    }
    static func needsManifest(_ sql: SQLDatabase, tenant: UUID, form: UUID, run: Run) async throws -> Bool {
        struct G: Decodable { let graph_json: String }
        guard let graph = try await sql.raw("SELECT w.graph_json FROM releases r JOIN workflow_versions w ON w.customer_id=r.customer_id AND w.workflow_id=r.workflow_id AND w.version_no=r.workflow_version_no WHERE r.id=\(bind: run.release_id) AND r.customer_id=\(bind: DB.bin(tenant)) AND r.form_id=\(bind: DB.bin(form))").first(decoding: G.self),
              let root = (try? JSONSerialization.jsonObject(with: Data(graph.graph_json.utf8))) as? [String: Any], let nodes = root["nodes"] as? [String: [String: Any]] else { throw Abort(.conflict) }
        return nodes.values.contains { node in
            guard let block = node["block"] as? [String: Any], let id = block["id"] as? String else { return false }
            return id == "core.mail" || id == "synthetic-mail"
        }
    }
    static func strictProofShape(_ req: Request) throws {
        guard let bytes = req.body.data, let root = try? JSONSerialization.jsonObject(with: Data(buffer: bytes)) as? [String: Any],
              let proof = root["originalProof"] as? [String: Any], Set(proof.keys) == ["objects"],
              let objects = proof["objects"] as? [[String: Any]], objects.count <= 1024,
              objects.allSatisfy({ Set($0.keys) == ["objectId", "expectedRevision", "expectedSha256", "cek"] }) else { throw Abort(.badRequest) }
    }
    static func noStore(_ response: Response) -> Response {
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return response
    }
    static func ids(_ req: Request) throws -> (UUID, UUID, UUID) { (try FormAdmin.uuidParam(req, "tenantId"), try FormAdmin.uuidParam(req, "formId"), try FormAdmin.uuidParam(req, "runId")) }
    static func checkpointHash(_ run: Run) -> String { ((try? JSONSerialization.jsonObject(with: Data(run.checkpoint_json.utf8))) as? [String: String])?["sha256"] ?? "" }
    static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64, value == value.lowercased() else { return nil }
        var bytes = [UInt8](); var i = value.startIndex
        while i < value.endIndex { let j = value.index(i, offsetBy: 2); guard let b = UInt8(value[i..<j], radix: 16) else { return nil }; bytes.append(b); i = j }; return Data(bytes)
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func lower(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func audit(_ sql: SQLDatabase, tenant: UUID, form: UUID, account: UUID, run: UUID, action: String, at: Date) async throws {
        try await ReleaseRoutes.audit(sql, tenant: tenant, form: form, actor: account, action: action, subject: run, at: DB.time(at), category: "flow").run()
    }
    struct RunBody: Encodable { let id: String; let state: String; let revision: UInt64 }
    static func objectBody(_ object: Object, access: String) throws -> ObjectBody {
        guard let id = DB.uuid(object.id.data), let generation = object.generation_id.flatMap({ DB.uuid($0.data) }), let payload = object.payload_sha256 else { throw Abort(.conflict) }
        return ObjectBody(objectId: lower(id), role: object.object_role, ordinal: object.ordinal_no, revision: object.revision, packageSha256: hex(object.ciphertext_sha256.data), payloadSha256: hex(payload.data), generationId: lower(generation), wrap: object.wrap_kind, byteCount: object.byte_count, access: access)
    }
    struct ObjectBody: Encodable { let objectId: String; let role: String; let ordinal: UInt64; let revision: UInt64; let packageSha256: String; let payloadSha256: String; let generationId: String; let wrap: String; let byteCount: UInt64; let access: String }
    struct ContextBody: Encodable {
        let runId: String; let state: String; let revision: UInt64; let checkpointHash: String; let checkpoint: ObjectBody; let manifestObjectId: String?; let requiredObjects: [ObjectBody]; let blocked: [String]
        enum CodingKeys: String, CodingKey { case runId, state, revision, checkpointHash, checkpoint, manifestObjectId, requiredObjects, blocked }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(runId, forKey: .runId); try c.encode(state, forKey: .state); try c.encode(revision, forKey: .revision)
            try c.encode(checkpointHash, forKey: .checkpointHash); try c.encode(checkpoint, forKey: .checkpoint)
            try c.encode(manifestObjectId, forKey: .manifestObjectId); try c.encode(requiredObjects, forKey: .requiredObjects); try c.encode(blocked, forKey: .blocked)
        }
    }
    struct CipherBody: Encodable { let object: ObjectBody; let package: String }
}
