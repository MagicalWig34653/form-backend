// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
@testable import FormCrypto
import FormFlow
import FormMail
import FormPersistence
import Foundation
import SQLKit
import TestSupport
import XCTest
import XCTVapor
@testable import FormAdmin

/// Real publication -> signed ingest -> workflow/checkpoint/effect integration. Synthetic data only.
final class FlowIngestTests: XCTestCase {
    private struct World {
        let tenant: UUID; let form: String; let client: TestClient; let system: TestClient
        let seed: Data; let key: Curve25519.KeyAgreement.PrivateKey
    }
    private struct Count: Decodable { let c: Int }
    private struct Run: Decodable { let id: Blob; let state: String; let steps_used: UInt64; let revision: UInt64; let checkpoint_json: String }
    private struct Checkpoint: Decodable { let ciphertext: Blob; let ciphertext_sha256: Blob; let revision: UInt64 }
    private struct Delivery: Decodable { let state: String; let attempts: Int; let effect_id: Blob? }
    private func requireDatabase() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["P4A_DB_PORT"].flatMap(Int.init) != nil, env["P4A_DB_PASSWORD"] != nil else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
    }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func parse(_ r: XCTHTTPResponse) throws -> JSONValue { try JCS.parse(Data(buffer: r.body)) }
    private func node(_ kind: String, _ extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(extra.merging(["kind": .string(kind), "label": .object(["de": .string(kind)])]) { _, b in b })
    }
    private func count(_ f: AdminFixture, _ table: String) async throws -> Int {
        try await f.sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first(decoding: Count.self)?.c ?? -1
    }
    private func modified(_ doc: JSONValue, flow: String?, content: String? = "full") throws -> JSONValue {
        var top = try XCTUnwrap(doc.object), form = try XCTUnwrap(top["form"]?.object)
        // One organisation mail makes duplicate delivery observable for both legacy and flow paths.
        var organisation: [String: JSONValue] = ["to": .array([.string("recipient@example.org")]), "subject": .string("Ablauf-Test"), "body": .string("#=[nachricht]=#")]
        if let content { organisation["content"] = .string(content) }
        form["mail"] = .object(["from": .object(["address": .string("sender@example.org")]), "organisation": .object(organisation)])
        top["form"] = .object(form)
        let formHash = DocHash.hex(DocHash.sha256(.object(form)))
        top["views"] = .array(try XCTUnwrap(top["views"]?.array).map { value in
            var v = value.object!, ref = v["form"]!.object!; ref["sha256"] = .string(formHash); v["form"] = .object(ref); return .object(v)
        })
        if let flow {
            var graph = try XCTUnwrap(top["flow"]?.object)
            var nodes: [String: JSONValue] = ["entry": node("entry"), "end": node("end", ["result": .string("success")])]
            nodes["set"] = node("block", ["block": try FlowDefinition.builtinReference(id: "core.set-fields"), "location": .string("backend-worker"),
                "config": .object(["values": .object(["nachricht": .string("FLOW-TRANSFORMED")])]), "inputBindings": .object([:])])
            var edges: [(String, String, String)] = [("entry", "next", "set"), ("set", "next", "action")]
            if flow == "mail" || flow == "webhook" || flow == "webhook-wait" {
                nodes["action"] = node("block", ["block": try FlowDefinition.builtinReference(id: flow == "mail" ? "core.mail" : "core.webhook"), "location": .string("backend-worker"), "config": .object([:]), "inputBindings": .object([:])])
                if flow == "webhook-wait" {
                    nodes["wait"] = node("wait", ["durationMs": .int(60000), "onTimeout": .string("fail")])
                    edges += [("action", "next", "wait"), ("wait", "resume", "end")]
                } else { edges.append(("action", "next", "end")) }
            } else if flow == "approval" || flow == "approval-fail" {
                nodes["action"] = node("approval", ["permission": .string("flow.approve"), "timeoutMs": .int(60000), "onTimeout": .string(flow == "approval-fail" ? "fail" : "reject"), "requireHuman": .bool(true)])
                nodes["rejected"] = node("end", ["result": .string("rejected")])
                edges += [("action", "approved", "end"), ("action", "rejected", "rejected")]
            } else {
                nodes["action"] = node("wait", ["durationMs": .int(60000), "onTimeout": .string("fail")])
                edges.append(("action", "resume", "end"))
            }
            graph["nodes"] = .object(nodes)
            graph["edges"] = .array(edges.map { .object(["from": .string($0.0), "port": .string($0.1), "to": .string($0.2)]) })
            top["flow"] = .object(graph)
        }
        return .object(top)
    }
    private func world(_ f: AdminFixture, flow: String?, content: String? = "full") async throws -> World {
        let root = try await f.account(), user = try await f.account(), system = try await f.account(), tenant = try await f.customer()
        for right in ["form.create", "form.read", "draft.write", "release.publish", "key.manage", "flow.execute", "flow.resume", "content.resend", "content.decrypt"] { try await f.grant(user, right, customer: tenant, by: root) }
        try await f.grant(system, "system.manage", system: true, by: root)
        let c = try await f.login(user), sys = try await f.login(system)
        var form = "", draft = "", doc = JSONValue.null, hash = "", confirmation = ""
        try await c.post("tenants/\(tenant)/forms", "{\"name\":\"Ablauf\"}") { XCTAssertEqual($0.status, .created, text($0)); form = jsonObject($0)["id"] as? String ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)") { draft = (jsonObject($0)["draftIds"] as? [String])?.first ?? "" }
        try await c.get("tenants/\(tenant)/forms/\(form)/drafts/\(draft)") { doc = try parse($0)["document"] ?? .null }
        doc = try modified(doc, flow: flow, content: content)
        try await c.send(.PATCH, "tenants/\(tenant)/forms/\(form)/drafts/\(draft)", body: String(decoding: JCS.canonicalize(doc), as: UTF8.self), headers: ["If-Match": "\"1\""]) {
            XCTAssertEqual($0.status, .ok, text($0)); hash = jsonObject($0)["hash"] as? String ?? ""
        }
        try await c.post("tenants/\(tenant)/forms/\(form)/publication-confirmations", "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirm\":true}") {
            XCTAssertEqual($0.status, .created, text($0)); confirmation = jsonObject($0)["confirmationId"] as? String ?? ""
        }
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/releases", body: "{\"draftId\":\"\(draft)\",\"revision\":2,\"hash\":\"\(hash)\",\"confirmationId\":\"\(confirmation)\"}", headers: ["Idempotency-Key": "publish"]) { XCTAssertEqual($0.status, .created, text($0)) }
        let sk = Curve25519.KeyAgreement.PrivateKey()
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(sk.publicKey.rawRepresentation.base64URLString)\"}") { XCTAssertEqual($0.status, .created) }
        var seed = Data()
        try await c.send(.POST, "tenants/\(tenant)/forms/\(form)/sdk-credentials") { seed = Data(base64URLString: jsonObject($0)["signingSeed"] as? String ?? "") ?? Data() }
        return World(tenant: tenant, form: form, client: c, system: sys, seed: seed, key: sk)
    }
    private func connect(_ w: World, _ smtp: FakeSMTPServer) async throws {
        var id = ""
        try await w.system.post("connections", "{\"kind\":\"smtp\",\"name\":\"Test\",\"config\":{\"host\":\"127.0.0.1\",\"port\":\(smtp.port),\"security\":\"plain\"}}") { XCTAssertEqual($0.status, .created, text($0)); id = jsonObject($0)["id"] as? String ?? "" }
        try await w.system.send(.PUT, "tenants/\(w.tenant)/connections/\(id)") { XCTAssertEqual($0.status, .noContent) }
        try await w.client.send(.PUT, "tenants/\(w.tenant)/forms/\(w.form)/mail-connection", body: "{\"connectionId\":\"\(id)\"}") { XCTAssertEqual($0.status, .noContent, text($0)) }
    }
    private func submit(_ f: AdminFixture, _ w: World, key: String = "submit") async throws -> String {
        let canonical = try RequestSignature.canonical(fields: .array([("nachricht", .string("FLOW-ORIGINAL"))]))
        let stamp = String(Int64(Date().timeIntervalSince1970))
        let signature = try RequestSignature.sign(try RequestSignature.signingText(route: .submit, formID: w.form, timestamp: stamp, canonical: canonical), seed: w.seed)
        var headers = HTTPHeaders(); headers.contentType = .urlEncodedForm
        headers.add(name: "X-Kubus-Timestamp", value: stamp); headers.add(name: "X-Kubus-Signature", value: signature.base64EncodedString()); headers.add(name: "Idempotency-Key", value: key)
        var id = ""
        try await f.app.test(.POST, "api/v2/submit/?f=\(w.form)", headers: headers, body: ByteBuffer(string: "nachricht=FLOW%2DORIGINAL")) {
            XCTAssertEqual($0.status, .ok, text($0)); id = (jsonObject($0)["submission"] as? [String: Any])?["id"] as? String ?? ""
        }
        return id
    }
    private func until(_ condition: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(30)  // 8 s was too tight on a loaded machine (delivery is asynchronous)
        while Date() < end { if try await condition() { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        XCTFail("Mailzustellung nicht abgeschlossen")
    }
    private func mailBody(_ smtp: FakeSMTPServer) -> String {
        guard let data = smtp.mails.first?.data else { return "" }
        let encoded = data.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n").replacingOccurrences(of: "\r\n", with: "")
        return String(decoding: Data(base64Encoded: encoded) ?? Data(), as: UTF8.self)
    }
    private func deliveryRows(_ f: AdminFixture) async throws -> [Delivery] {
        try await f.sql.raw("SELECT state,attempts,effect_id FROM mail_deliveries").all(decoding: Delivery.self)
    }
    private func checkpoint(_ f: AdminFixture, key: Curve25519.KeyAgreement.PrivateKey) async throws -> (Run, FlowState, Checkpoint) {
        let loadedRun = try await f.sql.raw("SELECT id,state,steps_used,revision,checkpoint_json FROM workflow_runs").first(decoding: Run.self)
        let row = try XCTUnwrap(loadedRun)
        let loadedObject = try await f.sql.raw("SELECT o.ciphertext,o.ciphertext_sha256,o.revision FROM stored_objects o JOIN workflow_runs r ON r.customer_id=o.customer_id AND r.checkpoint_object_id=o.id").first(decoding: Checkpoint.self)
        let object = try XCTUnwrap(loadedObject)
        let wire = String(decoding: object.ciphertext.data, as: UTF8.self)
        XCTAssertFalse(wire.contains("FLOW-TRANSFORMED")); XCTAssertFalse(row.checkpoint_json.contains("FLOW-TRANSFORMED"))
        XCTAssertEqual(Data(SHA256.hash(data: object.ciphertext.data)), object.ciphertext_sha256.data)
        let state = try FlowState(json: JCS.parse(try PackageV2(wire).open(recipient: key)))
        return (row, state, object)
    }
    func testStandardPlaceholderKeepsLegacyMailAndReplayWithoutWorkflow() async throws {
        try requireDatabase()
        let smtp = FakeSMTPServer(); try await smtp.start(); defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, flow: nil); try await connect(w, smtp)
            let first = try await submit(f, w)
            try await until { try await deliveryRows(f).first?.state == "smtp-accepted" }
            let replay = try await submit(f, w)
            XCTAssertEqual(first, replay); XCTAssertEqual(smtp.mails.count, 1)
            XCTAssertTrue(mailBody(smtp).contains("FLOW-ORIGINAL"))
            let deliveries = try await deliveryRows(f)
            XCTAssertEqual(deliveries.count, 1); XCTAssertNil(deliveries.first?.effect_id); XCTAssertEqual(deliveries.first?.attempts, 1)
            let runs = try await count(f, "workflow_runs"), effects = try await count(f, "workflow_effects"), submissions = try await count(f, "submissions")
            XCTAssertEqual(runs, 0); XCTAssertEqual(effects, 0); XCTAssertEqual(submissions, 1)
        }
    }
    func testPublishedFieldTransformWaitAndReplayKeepOnlyEncryptedCheckpoint() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "wait")
            let first = try await submit(f, w)
            let (run, state, object) = try await checkpoint(f, key: w.key)
            XCTAssertEqual(run.state, "waiting"); XCTAssertEqual(state.nodeID, "end"); XCTAssertEqual(state.fields["nachricht"], .string("FLOW-TRANSFORMED")); XCTAssertEqual(run.steps_used, 3)
            let replay = try await submit(f, w); XCTAssertEqual(first, replay)
            let (after, afterState, afterObject) = try await checkpoint(f, key: w.key)
            XCTAssertEqual(after.revision, run.revision); XCTAssertEqual(afterState, state); XCTAssertEqual(afterObject.revision, object.revision)
            let runs = try await count(f, "workflow_runs"), deliveries = try await count(f, "mail_deliveries")
            XCTAssertEqual(runs, 1); XCTAssertEqual(deliveries, 0, "Ablauf mit Warten darf die frühere Mailpipeline nicht zusätzlich starten")
        }
    }
    func testPublishedApprovalCreatesGateWithoutSendingOrAutomaticContinuation() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "approval"); _ = try await submit(f, w)
            let (run, state, _) = try await checkpoint(f, key: w.key)
            XCTAssertEqual(run.state, "waiting"); XCTAssertEqual(state.nodeID, "end")
            let gates = try await count(f, "workflow_approvals"), effects = try await count(f, "workflow_effects"), deliveries = try await count(f, "mail_deliveries")
            XCTAssertEqual(gates, 1); XCTAssertEqual(effects, 0); XCTAssertEqual(deliveries, 0)
            let runID = try XCTUnwrap(DB.uuid(run.id.data))
            let lease = try await FlowStore(db: f.app.db(.mysql)).claim(run: runID, now: Date().addingTimeInterval(120))
            XCTAssertNil(lease, "Abgelaufenes Gate darf ohne menschliches Resume keinen Worker starten")
        }
    }
    func testFlowMailHasOneConfirmedEffectAndReplayCannotDeliverAgain() async throws {
        try requireDatabase()
        let smtp = FakeSMTPServer(); try await smtp.start(); defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "mail"); try await connect(w, smtp)
            let first = try await submit(f, w)
            let (run, state, _) = try await checkpoint(f, key: w.key)
            XCTAssertEqual(run.state, "complete"); XCTAssertEqual(state.fields["nachricht"], .string("FLOW-TRANSFORMED"))
            XCTAssertTrue(mailBody(smtp).contains("FLOW-TRANSFORMED")); XCTAssertFalse(mailBody(smtp).contains("FLOW-ORIGINAL"))
            let rows = try await deliveryRows(f)
            XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.state, "smtp-accepted"); XCTAssertNotNil(rows.first?.effect_id)
            struct Effect: Decodable { let state: String }
            let effects = try await f.sql.raw("SELECT state FROM workflow_effects").all(decoding: Effect.self)
            XCTAssertEqual(effects.map(\.state), ["confirmed"])
            let replay = try await submit(f, w); XCTAssertEqual(first, replay); XCTAssertEqual(smtp.mails.count, 1)
            let after = try await deliveryRows(f); XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.attempts, 1)
            // Even an explicit second engine call cannot claim a completed run.
            try await FlowEngine(db: f.app.db(.mysql)).execute(run: try XCTUnwrap(DB.uuid(run.id.data)), state: FlowState(nodeID: "entry", fields: ["nachricht": .string("DUPLICATE")]))
            XCTAssertEqual(smtp.mails.count, 1)
        }
    }
    /// ADR 0041: the flow mail block with an explicit `content: notification` sends no field value, not even a transformed one.
    func testFlowMailInNotificationModeCarriesNoFieldValue() async throws {
        try requireDatabase()
        let smtp = FakeSMTPServer(); try await smtp.start(); defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "mail", content: "notification"); try await connect(w, smtp)
            let id = try await submit(f, w)
            try await until { smtp.mails.count == 1 }
            let wire = try XCTUnwrap(smtp.mails.first).data, body = mailBody(smtp)
            for secret in ["FLOW-TRANSFORMED", "FLOW-ORIGINAL", "Ablauf-Test"] { XCTAssertFalse(wire.contains(secret) || body.contains(secret), secret) }
            XCTAssertTrue(body.contains("Formular: Ablauf"), body)
            XCTAssertTrue(body.contains("Kennung: \(id)"), body)
            XCTAssertTrue(body.contains("\(AdminFixture.origin)/t/\(w.tenant.uuidString.lowercased())/f/\(w.form)/entries"), body)
            XCTAssertFalse(wire.lowercased().contains("reply-to:"))
        }
    }
    func testAutomaticWebhooksOnlyForStandardPlaceholderAndNeverOnReplay() async throws {
        for flow: String? in [nil, "wait"] {
            try await AdminFixture.with { f in
                let w = try await world(f, flow: flow)
                let activeEndpoint = UUID()
                for (endpoint, active) in [(activeEndpoint, 1), (UUID(), 0)] {
                    try await f.sql.raw("""
                        INSERT INTO webhook_endpoints (id,customer_id,form_id,target_url,signing_secret_ref,public_key,active,created_at)
                        VALUES (\(bind: DB.bin(endpoint)),\(bind: DB.bin(w.tenant)),\(bind: DB.bin(UUID(uuidString: w.form)!)),
                          'https://synthetic.invalid/hook','synthetic',\(bind: Blob(Data(repeating: 41, count: 32))),\(bind: active),NOW(6))
                        """).run()
                }
                let first = try await submit(f, w)
                let replay = try await submit(f, w)
                XCTAssertEqual(first, replay)
                struct Queued: Decodable { let webhook_id: Blob; let effect_id: Blob?; let state: String; let attempts: Int }
                let rows = try await f.sql.raw("SELECT webhook_id,effect_id,state,attempts FROM webhook_outbox").all(decoding: Queued.self)
                XCTAssertEqual(rows.count, flow == nil ? 1 : 0, "Eigene Flows ohne Webhook-Baustein dürfen keinen automatischen Webhook auslösen")
                if flow == nil {
                    XCTAssertEqual(rows.first?.webhook_id, DB.bin(activeEndpoint))
                    XCTAssertNil(rows.first?.effect_id)
                    XCTAssertEqual(rows.first?.state, "ready")
                    XCTAssertEqual(rows.first?.attempts, 0)
                }
            }
        }
    }

    func testFlowWebhookIsQueuedOnceWithConfirmedEffectAndNoNetworkDelivery() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "webhook")
            let endpoint = UUID()
            try await f.sql.raw("""
                INSERT INTO webhook_endpoints (id,customer_id,form_id,target_url,signing_secret_ref,public_key,active,created_at)
                VALUES (\(bind: DB.bin(endpoint)),\(bind: DB.bin(w.tenant)),\(bind: DB.bin(UUID(uuidString: w.form)!)),
                  'https://synthetic.invalid/flow-hook','synthetic-flow-webhook-secret',\(bind: Blob(Data(repeating: 41, count: 32))),1,NOW(6))
                """).run()
            let first = try await submit(f, w)
            let (run, _, _) = try await checkpoint(f, key: w.key)
            XCTAssertEqual(run.state, "complete")
            struct Queued: Decodable { let state: String; let attempts: Int; let effect_id: Blob?; let webhook_id: Blob; let submission_id: Blob }
            let queue = try await f.sql.raw("SELECT state,attempts,effect_id,webhook_id,submission_id FROM webhook_outbox").all(decoding: Queued.self)
            XCTAssertEqual(queue.count, 1); XCTAssertEqual(queue.first?.state, "ready"); XCTAssertEqual(queue.first?.attempts, 0)
            XCTAssertNotNil(queue.first?.effect_id); XCTAssertEqual(queue.first?.webhook_id.data, DB.bin(endpoint).data)
            XCTAssertEqual(queue.first?.submission_id.data, DB.bin(UUID(uuidString: first)!).data)
            struct Effect: Decodable { let id: Blob; let state: String }
            let effects = try await f.sql.raw("SELECT id,state FROM workflow_effects").all(decoding: Effect.self)
            XCTAssertEqual(effects.count, 1); XCTAssertEqual(effects.first?.state, "confirmed"); XCTAssertEqual(effects.first?.id.data, queue.first?.effect_id?.data)
            let replay = try await submit(f, w); XCTAssertEqual(first, replay)
            let queued = try await count(f, "webhook_outbox"), effectCount = try await count(f, "workflow_effects"), deliveries = try await count(f, "mail_deliveries")
            XCTAssertEqual(queued, 1); XCTAssertEqual(effectCount, 1); XCTAssertEqual(deliveries, 0)
        }
    }

    func testApprovalTimeoutRejectsOrFailsWithoutStartingWorker() async throws {
        for kind in ["approval", "approval-fail"] {
            try await AdminFixture.with { f in
                let w = try await world(f, flow: kind); _ = try await submit(f, w)
                let (before, _, _) = try await checkpoint(f, key: w.key)
                let store = FlowStore(db: f.app.db(.mysql))
                try await store.expireWaiting(now: Date().addingTimeInterval(61))
                let (after, _, _) = try await checkpoint(f, key: w.key)
                XCTAssertEqual(after.state, kind == "approval" ? "waiting-manual" : "failed")
                XCTAssertGreaterThan(after.revision, before.revision)
                struct Gate: Decodable { let state: String }
                let gate = try await f.sql.raw("SELECT state FROM workflow_approvals").first(decoding: Gate.self)
                XCTAssertEqual(gate?.state, "expired")
                let mails = try await count(f, "mail_deliveries")
                XCTAssertEqual(mails, 0)
            }
        }
    }

    func testCancelRemovesOnlyReadyWebhooksAndCheckpointResponsesDisableCaching() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "webhook-wait")
            try await f.sql.raw("""
                INSERT INTO webhook_endpoints (id,customer_id,form_id,target_url,signing_secret_ref,public_key,active,created_at)
                VALUES (\(bind: DB.bin(UUID())),\(bind: DB.bin(w.tenant)),\(bind: DB.bin(UUID(uuidString: w.form)!)),
                  'https://synthetic.invalid/hook','synthetic',\(bind: Blob(Data(repeating: 41, count: 32))),1,NOW(6))
                """).run()
            _ = try await submit(f, w)
            let (run, _, _) = try await checkpoint(f, key: w.key)
            let path = "tenants/\(w.tenant)/forms/\(w.form)/runs/\(DB.uuid(run.id.data)!)"
            for suffix in ["/resume-context", "/checkpoint/ciphertext"] {
                try await w.client.get(path + suffix) {
                    XCTAssertEqual($0.status, .ok, text($0)); XCTAssertEqual($0.headers.first(name: .cacheControl), "no-store")
                }
            }
            try await w.client.post(path + "/cancel", "{\"expectedRevision\":\(run.revision)}") { XCTAssertEqual($0.status, .ok, text($0)) }
            struct State: Decodable { let state: String; let last_error_code: String?; let completed_at: Date?; let next_attempt_at: Date? }
            let outbox = try await f.sql.raw("SELECT state,last_error_code,completed_at,next_attempt_at FROM webhook_outbox").all(decoding: State.self)
            XCTAssertEqual(outbox.map(\.state), ["failed-terminal"])
            XCTAssertEqual(outbox.first?.last_error_code, "flow-stopped")
            XCTAssertNotNil(outbox.first?.completed_at)
            XCTAssertNil(outbox.first?.next_attempt_at)
        }
    }

    private struct NoSecrets: MailSecretProvider { func secret(ref: String) async throws -> String? { nil } }
    func testPreparedMailReusesDeliveryAndLateCancellationPreventsTransport() async throws {
        try requireDatabase()
        let smtp = FakeSMTPServer(); try await smtp.start(); defer { Task { await smtp.stop() } }
        try await AdminFixture.with { f in
            let w = try await world(f, flow: "mail")
            let entry = try await submit(f, w) // no connection: the effect has never started
            let (run, state, _) = try await checkpoint(f, key: w.key)
            let runID = try XCTUnwrap(DB.uuid(run.id.data))
            struct D: Decodable { let id: Blob; let effect_id: Blob; let release_id: Blob }
            let deliveryRow = try await f.sql.raw("SELECT d.id,d.effect_id,s.release_id FROM mail_deliveries d JOIN submissions s ON s.id=d.submission_id").first(decoding: D.self)
            let delivery = try XCTUnwrap(deliveryRow)
            try await w.client.post("tenants/\(w.tenant)/forms/\(w.form)/entries/\(entry)/resends", "{\"deliveryId\":\"\(DB.uuid(delivery.id.data)!.uuidString.lowercased())\",\"contentKey\":\"\(Data(repeating: 0, count: 32).base64URLString)\"}") {
                XCTAssertEqual($0.status, .conflict, text($0))
                // Abort reasons are intentionally replaced with fixed public messages by ProblemMiddleware.
                XCTAssertEqual(jsonObject($0)["code"] as? String, "conflict", text($0))
                XCTAssertEqual(jsonObject($0)["message"] as? String, "Konflikt.", text($0))
            }
            try await connect(w, smtp)
            try await f.sql.raw("UPDATE workflow_runs SET state='ready',lease_token=\(bind: DB.bin(UUID())),lease_until=\(bind: DB.time(Date().addingTimeInterval(300))) WHERE id=\(bind: run.id)").run()
            let store = FlowStore(db: f.app.db(.mysql))
            let claimed = try await store.claim(run: runID, now: Date()), lease = try XCTUnwrap(claimed)
            let effect = try await store.reserveEffect(lease: lease, node: "action", visit: UInt64(state.steps), slot: "organisation", now: Date())
            XCTAssertEqual(DB.bin(effect.id), delivery.effect_id); XCTAssertEqual(effect.state, "prepared")
            let planRow = try await MailDispatcher.plan(db: f.sql, customer: DB.bin(w.tenant), form: DB.bin(UUID(uuidString: w.form)!), release: delivery.release_id)
            let plan = try XCTUnwrap(planRow)
            let dispatcher = MailDispatcher(db: f.app.db(.mysql), secrets: NoSecrets(), allowedNets: [CIDR("127.0.0.0/8")!], allowInsecure: true, logger: f.app.logger)
            let prepared = try await f.app.db(.mysql).transaction { conn in
                try await store.assertLease(conn as! SQLDatabase, lease: lease, now: Date())
                return try await dispatcher.prepare(tx: conn as! SQLDatabase, plan: plan, customer: lease.customer, form: lease.form, submission: UUID(uuidString: entry)!, fields: ["nachricht":"FLOW-TRANSFORMED"], identityScope: effect.id.uuidString.lowercased(), effectID: effect.id, onlyKind: "organisation")
            }
            XCTAssertEqual(prepared.first?.deliveryID, DB.uuid(delivery.id.data))
            try await f.sql.raw("UPDATE workflow_runs SET state='cancelled',fence=fence+1,lease_token=NULL,lease_until=NULL WHERE id=\(bind: run.id)").run()
            await dispatcher.deliver(try XCTUnwrap(prepared.first), beforeSend: { try await store.beginEffect(lease: lease, effect: effect.id, now: Date()) })
            XCTAssertEqual(smtp.mails.count, 0)
        }
    }

}
