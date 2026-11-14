// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FluentMySQLDriver
import FormCore
import FormCrypto
import FormMail
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Executes only while plaintext is supplied by ingest or a verified human resume.
public struct FlowEngine {
    public let db: Database
    public let mail: MailDispatcher?
    public init(db: Database, mail: MailDispatcher? = nil) { self.db = db; self.mail = mail }
    struct Published: Decodable { let graph_json: String; let graph_sha256: Blob; let contract_version: String; let dependency_manifest_json: String; let manifest_sha256: Blob }
    public static func definition(sql: SQLDatabase, customer: Blob, form: Blob, release: Blob) async throws -> FlowDefinition? {
        guard let r = try await sql.raw("""
            SELECT w.graph_json,w.graph_sha256,w.contract_version,r.dependency_manifest_json,r.manifest_sha256 FROM releases r JOIN workflow_versions w
              ON w.customer_id=r.customer_id AND w.workflow_id=r.workflow_id AND w.version_no=r.workflow_version_no
            WHERE r.id=\(bind: release) AND r.customer_id=\(bind: customer) AND r.form_id=\(bind: form)
            """).first(decoding: Published.self) else { throw FlowError.invalidDefinition }
        let canonical = try JCS.canonicalize(json: Data(r.graph_json.utf8))
        guard r.contract_version == "0.1.0", Data(SHA256.hash(data: canonical)) == r.graph_sha256.data else { throw FlowError.invalidDefinition }
        let manifestData = try JCS.canonicalize(json: Data(r.dependency_manifest_json.utf8))
        guard Data(SHA256.hash(data: manifestData)) == r.manifest_sha256.data,
              let manifest = try JCS.parse(manifestData).flowObject,
              manifest["flow"]?.flowObject?["sha256"] == .string(r.graph_sha256.data.map { String(format: "%02x", $0) }.joined()) else { throw FlowError.invalidDefinition }
        let d = try FlowDefinition.load(graph: canonical, blocks: FlowDefinition.builtinBlocks, modules: FlowDefinition.builtinModules)
        let usedRefs = d.nodes.values.compactMap { $0.flowObject?["block"] }
        guard manifest["blocks"]?.flowArray?.count == Set(usedRefs.compactMap { $0.flowObject?["id"]?.flowString }).count,
              usedRefs.allSatisfy({ manifest["blocks"]?.flowArray?.contains($0) == true }) else { throw FlowError.invalidDefinition }
        if !usedRefs.isEmpty {
            let expected: [JSONValue] = try FlowDefinition.builtinModules.map { data in
                let module = try JCS.parse(data).flowObject!
                return .object(["id": module["id"]!, "version": module["version"]!, "sha256": .string(Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined())])
            }
            guard manifest["modules"] == .array(expected) else { throw FlowError.invalidDefinition }
        }
        // Existing releases always contain the standard entry→end placeholder.
        if d.nodes.count == 2, Set(d.nodes.values.compactMap { $0.flowObject?["kind"]?.flowString }) == ["entry", "end"], d.nodes.values.contains(where: { $0.flowObject?["kind"] == .string("end") && $0.flowObject?["result"] == .string("success") }) { return nil }
        return d
    }
    public static func initialState(_ d: FlowDefinition, fields: Data) throws -> FlowState {
        guard case .object(let f) = try JCS.parse(fields) else { throw FlowError.invalidState }
        return FlowState(nodeID: d.entryNode, fields: f)
    }
    @discardableResult
    public func prepare(tx: SQLDatabase, definition: FlowDefinition, state: FlowState, customer: Blob, form: Blob, release: Blob, submission: UUID, publicKey: Data, digest: Data, digestGeneration: Int64, now: Date) async throws -> UUID {
        guard JCS.canonicalize(state.json).count <= min(definition.limits.maxStateBytes, definition.limits.memoryBytes) else { throw FlowError.budgetExceeded }
        let object = UUID()
        let sealed = try PackageV2.seal(JCS.canonicalize(state.json), recipient: publicKey)
        let wire = Data(sealed.wire.utf8), hash = Data(SHA256.hash(data: wire))
        try await tx.raw("""
            INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,ordinal_no,revision,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state)
            VALUES (\(bind: DB.bin(object)),\(bind: customer),\(bind: form),\(bind: DB.bin(submission)),'checkpoint',0,0,'db',\(bind: ChunkedBlob.head(wire)),'KUBUS-AEAD:2','hpke',\(bind: sealed.kid),'raw',\(bind: Blob(hash)),\(bind: Blob(Data(SHA256.hash(data: sealed.iv + sealed.ciphertext + sealed.tag)))),\(bind: wire.count),'ready')
            """).run()
        // State is capped by maxStateBytes (1 MiB in the catalog), but a definition may raise it: above the driver packet limit the cell is appended in pieces.
        try await ChunkedBlob.append(wire, to: .objectCiphertext, key: DB.bin(object), on: tx)
        return try await FlowStore(db: db).create(tx: tx, customer: customer, form: form, submission: submission, release: release, checkpointObject: object, checkpointHash: hash, budgetJSON: "{\"maxSteps\":\(definition.limits.maxSteps),\"activeTimeoutMs\":\(definition.limits.activeTimeoutMs)}", digest: digest, digestGeneration: digestGeneration, deadline: now.addingTimeInterval(Double(definition.limits.maxElapsedMs)/1000), now: now)
    }
    struct Context: Decodable { let submission_id: Blob; let release_id: Blob; let checkpoint_object_id: Blob; let public_key: Blob; let active_time_ms: UInt64 }
    public func execute(run: UUID, state: FlowState) async throws {
        guard let lease = try await FlowStore(db: db).claim(run: run, now: Date()) else { return }
        try await execute(lease: lease, state: state)
    }
    public func execute(lease: FlowStore.Lease, state initial: FlowState) async throws {
        let store = FlowStore(db: db), sql = db as! SQLDatabase
        guard let c = try await sql.raw("""
            SELECT r.submission_id,r.release_id,r.checkpoint_object_id,k.public_key,r.active_time_ms FROM workflow_runs r
            JOIN stored_objects o ON o.id=r.checkpoint_object_id AND o.customer_id=r.customer_id
            JOIN customer_key_generations k ON k.customer_id=o.customer_id AND k.kid=o.kid
            WHERE r.id=\(bind: DB.bin(lease.run)) AND r.customer_id=\(bind: lease.customer) AND r.form_id=\(bind: lease.form)
            """).first(decoding: Context.self), let submission = DB.uuid(c.submission_id.data), let object = DB.uuid(c.checkpoint_object_id.data),
              let definition = try await Self.definition(sql: sql, customer: lease.customer, form: lease.form, release: c.release_id) else { throw FlowError.invalidDefinition }
        var state = initial
        let started = Date()
        var processingNode = state.nodeID
        func save(_ state: FlowState, _ status: FlowStore.State, wakeAt: Date? = nil, suspension: String? = nil) async throws {
            let package = try PackageV2.seal(JCS.canonicalize(state.json), recipient: c.public_key.data)
            let wire = Data(package.wire.utf8), hash = Data(SHA256.hash(data: wire))
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                try await store.assertLease(tx, lease: lease, now: Date())
                try await tx.raw("UPDATE workflow_runs SET active_time_ms=\(bind: c.active_time_ms + UInt64(max(0, Date().timeIntervalSince(started)*1000))) WHERE id=\(bind: DB.bin(lease.run))").run()
                try await tx.raw("""
                    UPDATE stored_objects SET ciphertext=\(bind: ChunkedBlob.head(wire)),ciphertext_sha256=\(bind: Blob(hash)),payload_sha256=\(bind: Blob(Data(SHA256.hash(data: package.iv + package.ciphertext + package.tag)))),byte_count=\(bind: wire.count),revision=revision+1
                    WHERE id=\(bind: DB.bin(object)) AND customer_id=\(bind: lease.customer) AND form_id=\(bind: lease.form)
                    """).run()
                try await ChunkedBlob.append(wire, to: .objectCiphertext, key: DB.bin(object), on: tx)
                try await store.checkpoint(tx: tx, lease: lease, object: object, hash: hash, state: status, steps: UInt64(state.steps), now: Date(), wakeAt: wakeAt, suspensionKind: suspension)
                struct DebugRefs: Decodable { let definition_json: String; let definition_sha256: Blob; let manifest_sha256: Blob; let release_version_no: UInt64 }
                if let tenantID = DB.uuid(lease.customer.data), let formID = DB.uuid(lease.form.data), let releaseID = DB.uuid(c.release_id.data),
                   let refs = try await tx.raw("""
                    SELECT f.definition_json,f.definition_sha256,r.manifest_sha256,r.release_version_no FROM releases r
                    JOIN form_versions f ON f.customer_id=r.customer_id AND f.form_id=r.form_id AND f.version_no=r.form_version_no
                    WHERE r.customer_id=\(bind: lease.customer) AND r.form_id=\(bind: lease.form) AND r.id=\(bind: c.release_id)
                    """).first(decoding: DebugRefs.self),
                   let version = try JCS.parse(Data(refs.definition_json.utf8)).flowObject?["version"]?.flowString {
                    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
                    let kind: FlowDebugEvent.Kind = status == .waiting ? .suspended : (status == .waitingManual || status == .failed ? .failed : .nodeFinished)
                    let debugStatus: FlowDebugEvent.Status = status == .waiting || status == .waitingManual ? .waiting : (status == .failed ? .failed : .success)
                    try await FlowDebugStore.record(on: tx, tenant: tenantID, form: formID, release: releaseID, submission: submission, execution: lease.run,
                        formRef: .init(id: formID, version: version, sha256: hex(refs.definition_sha256.data)),
                        releaseRef: .init(id: releaseID, version: "\(refs.release_version_no).0.0", sha256: hex(refs.manifest_sha256.data)),
                        kind: kind, node: processingNode, visit: max(1, state.steps), status: debugStatus, now: Date())
                }

            }
        }
        do {
            while true {
                guard Date().timeIntervalSince(started)*1000 < Double(definition.limits.activeTimeoutMs) - Double(c.active_time_ms) else { throw FlowError.budgetExceeded }
                processingNode = state.nodeID
                switch try FlowInterpreter.step(definition: definition, state: state) {
                case .next(let next): state = next; try await save(state, .running)
                case .end(let result, let next): try await save(next, result == "success" ? .complete : .failed); return
                case .waiting(let kind, let duration, let next):
                    if kind == "approval" { _ = try await store.approval(lease: lease, node: processingNode, visit: UInt64(state.steps), expires: Date().addingTimeInterval(Double(duration)/1000), now: Date()) }
                    try await save(next, .waiting, wakeAt: kind == "timer" ? Date().addingTimeInterval(Double(duration)/1000) : nil, suspension: kind)
                    return
                case .effect(let kind, let node, _, _, var next):
                    if kind == "mail" {
                        guard let mail, let plan = try await MailDispatcher.plan(db: sql, customer: lease.customer, form: lease.form, release: c.release_id) else { throw FlowError.unsupportedCapability }
                        for slot in ["organisation", "confirmation"] where slot == "organisation" ? plan.organisation != nil : plan.confirmation != nil {
                            let effect = try await store.reserveEffect(lease: lease, node: node, visit: UInt64(state.steps), slot: slot, now: Date())
                            if effect.state == "confirmed" { continue }
                            guard effect.state == "prepared" else { throw FlowStore.StoreError.blocked }
                            let fields = try JSONSerialization.jsonObject(with: JCS.canonicalize(.object(state.fields))) as! [String: Any]
                            let prepared = try await db.transaction { conn -> [PreparedMail] in
                                let tx = conn as! SQLDatabase
                                try await store.assertLease(tx, lease: lease, now: Date())
                                return try await mail.prepare(tx: tx, plan: plan, customer: lease.customer, form: lease.form, submission: submission, fields: fields, identityScope: effect.id.uuidString.lowercased(), effectID: effect.id, onlyKind: slot)
                            }
                            guard prepared.count == 1 else { throw FlowStore.StoreError.blocked }
                            await mail.deliver(prepared[0], beforeSend: {
                                try await store.beginEffect(lease: lease, effect: effect.id, now: Date())
                            })
                            struct Delivery: Decodable { let state: String }
                            let accepted = try await sql.raw("SELECT state FROM mail_deliveries WHERE effect_id=\(bind: DB.bin(effect.id))").first(decoding: Delivery.self)?.state == "smtp-accepted"
                            try await store.finishEffect(lease: lease, effect: effect.id, confirmed: accepted, now: Date())
                            guard accepted else { throw FlowStore.StoreError.blocked }
                        }
                    } else {
                        struct Endpoint: Decodable { let id: Blob }
                        let endpoints = try await sql.raw("SELECT id FROM webhook_endpoints WHERE customer_id=\(bind: lease.customer) AND form_id=\(bind: lease.form) AND active=1 ORDER BY id").all(decoding: Endpoint.self)
                        guard !endpoints.isEmpty else { throw FlowError.unsupportedCapability }
                        for endpoint in endpoints {
                            guard let id = DB.uuid(endpoint.id.data) else { throw FlowError.invalidState }
                            try await db.transaction { conn in
                                let tx = conn as! SQLDatabase
                                let e = try await store.reserveEffect(tx: tx, lease: lease, node: node, visit: UInt64(state.steps), slot: id.uuidString.lowercased(), now: Date())
                                if e.state == "confirmed" { return }
                                guard e.state == "prepared" else { throw FlowStore.StoreError.blocked }
                                try await tx.raw("""
                                    INSERT INTO webhook_outbox (id,customer_id,form_id,webhook_id,submission_id,received_at,effect_id,state,attempts,fence,created_at)
                                    VALUES (\(bind: DB.bin(UUID())),\(bind: lease.customer),\(bind: lease.form),\(bind: endpoint.id),\(bind: c.submission_id),\(bind: DB.time(Date())),\(bind: DB.bin(e.id)),'ready',0,0,\(bind: DB.time(Date())))
                                    """).run()
                                try await tx.raw("UPDATE workflow_effects SET state='confirmed' WHERE id=\(bind: DB.bin(e.id)) AND state='prepared'").run()
                            }
                        }
                    }
                    next.outputs[node] = .object(["valid": .bool(true)])
                    state = next; try await save(state, .running)
                }
            }
        } catch { try? await save(state, .waitingManual); throw error }
    }
}
