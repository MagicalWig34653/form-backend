// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormCrypto
import FormFlow
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class FlowRunTests: XCTestCase {
    private func checkpoint() throws -> (FlowRunRoutes.Object, FlowRunRoutes.Proof, FlowState) {
        let sk = Curve25519.KeyAgreement.PrivateKey(), id = UUID()
        let state = FlowState(nodeID: "finish", fields: ["private": .string("synthetic-secret")], steps: 2)
        let packet = try PackageV2.seal(JCS.canonicalize(state.json), recipient: sk.publicKey.rawRepresentation)
        let wire = Data(packet.wire.utf8)
        let cek = try HPKE.open(packet.b, enc: packet.a, recipient: sk, info: Data("kubus-anfrage v2".utf8), aad: Data(packet.kid.utf8))
        let hash = Data(SHA256.hash(data: wire))
        let object = FlowRunRoutes.Object(id: DB.bin(id), object_role: "checkpoint", revision: 3, ciphertext: Blob(wire), ciphertext_sha256: Blob(hash),
            payload_sha256: Blob(Data(SHA256.hash(data: packet.iv + packet.ciphertext + packet.tag))), kid: packet.kid, state: "ready", ordinal_no: 0, generation_id: DB.bin(UUID()), wrap_kind: "hpke", byte_count: UInt64(wire.count))
        let proof = FlowRunRoutes.Proof(objectId: id.uuidString.lowercased(), expectedRevision: 3, expectedSha256: FlowRunRoutes.hex(hash), cek: cek.base64EncodedString())
        return (object, proof, state)
    }
    func testFlowResumeAuthenticatesStoredCheckpointAndRejectsStaleOrForeignProofs() throws {
        let (object, proof, expected) = try checkpoint()
        let opened = try FlowRunRoutes.validateProof(.init(objects: [proof]), objects: [object], checkpoint: object.id)
        XCTAssertEqual(opened, expected)
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: []), objects: [object], checkpoint: object.id))
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: [proof, proof]), objects: [object], checkpoint: object.id))
        let stale = FlowRunRoutes.Proof(objectId: proof.objectId, expectedRevision: 2, expectedSha256: proof.expectedSha256, cek: proof.cek)
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: [stale]), objects: [object], checkpoint: object.id))
        let foreign = FlowRunRoutes.Proof(objectId: UUID().uuidString.lowercased(), expectedRevision: 3, expectedSha256: proof.expectedSha256, cek: proof.cek)
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: [foreign]), objects: [object], checkpoint: object.id))
    }
    func testFlowResumeRejectsWrongKeysAndTamperedStoredPacket() throws {
        let (object, proof, _) = try checkpoint()
        let wrong = FlowRunRoutes.Proof(objectId: proof.objectId, expectedRevision: 3, expectedSha256: proof.expectedSha256, cek: Data(repeating: 0, count: 32).base64EncodedString())
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: [wrong]), objects: [object], checkpoint: object.id))
        let corrupt = FlowRunRoutes.Object(id: object.id, object_role: object.object_role, revision: object.revision, ciphertext: Blob(Data("tampered".utf8)), ciphertext_sha256: object.ciphertext_sha256,
            payload_sha256: object.payload_sha256, kid: object.kid, state: "ready", ordinal_no: 0, generation_id: object.generation_id, wrap_kind: "hpke", byte_count: 8)
        XCTAssertThrowsError(try FlowRunRoutes.validateProof(.init(objects: [proof]), objects: [corrupt], checkpoint: object.id))
    }
    func testFlowApprovalChoosesRejectedPortAndIgnoresHistoricalDecisions() throws {
        let graph = Data("""
        {"contractVersion":"0.1.0","proposalStatus":"VORGESCHLAGEN","id":"11111111-1111-4111-8111-111111111111","version":"1.0.0","engineContractVersion":"0.1.0","entryNode":"entry",
         "limits":{"maxSteps":100,"activeTimeoutMs":1000,"maxElapsedMs":10000,"memoryBytes":1048576,"nodeTimeoutMs":1000,"maxStateBytes":1048576},
         "nodes":{"entry":{"kind":"entry","label":{"de":"Start"}},"approval":{"kind":"approval","label":{"de":"Freigabe"},"permission":"flow.approve","timeoutMs":1000,"onTimeout":"reject","requireHuman":true},"accepted":{"kind":"end","label":{"de":"Erfolg"},"result":"success"},"rejected":{"kind":"end","label":{"de":"Abgelehnt"},"result":"rejected"}},
         "edges":[{"from":"entry","port":"next","to":"approval"},{"from":"approval","port":"approved","to":"accepted"},{"from":"approval","port":"rejected","to":"rejected"}],"failurePolicy":"stop-and-record"}
        """.utf8)
        let definition = try FlowDefinition.load(graph: graph)
        let now = Date(), checkpoint = FlowState(nodeID: "accepted", fields: [:], steps: 2)
        let rejected = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "rejected", expires_at: now.addingTimeInterval(60))
        let approved = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "approved", expires_at: now.addingTimeInterval(60))
        XCTAssertEqual(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: rejected, now: now).nodeID, "rejected")
        XCTAssertEqual(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: approved, now: now).nodeID, "accepted")
        let pending = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "pending", expires_at: now.addingTimeInterval(60))
        XCTAssertThrowsError(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: pending, now: now))
        let expired = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "approved", expires_at: now.addingTimeInterval(-1))
        XCTAssertEqual(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: expired, now: now).nodeID, "accepted", "A timely human decision remains valid after gate expiry")
        let timeout = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "expired", expires_at: now.addingTimeInterval(-1))
        XCTAssertEqual(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: timeout, now: now).nodeID, "rejected")
        let elapsed = FlowRunRoutes.Approval(node_id: "approval", visit_no: 1, state: "pending", expires_at: now.addingTimeInterval(-1))
        XCTAssertEqual(try FlowRunRoutes.applyApproval(checkpoint, definition: definition, approval: elapsed, now: now).nodeID, "rejected")
        let failGraph = Data(String(decoding: graph, as: UTF8.self).replacingOccurrences(of: "\"onTimeout\":\"reject\"", with: "\"onTimeout\":\"fail\"").utf8)
        XCTAssertThrowsError(try FlowRunRoutes.applyApproval(checkpoint, definition: FlowDefinition.load(graph: failGraph), approval: timeout, now: now))
        let later = FlowState(nodeID: "accepted", fields: [:], steps: 4)
        XCTAssertEqual(try FlowRunRoutes.applyApproval(later, definition: definition, approval: expired, now: now), later)
    }
    func testFlowResponsesDisableCaching() throws {
        let response = try FlowRunRoutes.noStore(FormAdmin.json(.ok, FlowRunRoutes.RunBody(id: "synthetic", state: "waiting", revision: 1)))
        XCTAssertEqual(response.headers.first(name: .cacheControl), "no-store")
    }
    func testFlowRunRoutesRequireHumanAuthenticationAndDoNotRevealForeignRun() async throws {
        try await AdminFixture.with { f in
            let account = try await f.account(), root = try await f.account(), tenant = try await f.customer()
            let form = try await f.form(customer: tenant), run = UUID()
            let path = "tenants/\(tenant)/forms/\(form)/runs/\(run)"
            let anon = TestClient(app: f.app, cookie: nil, csrf: nil)
            try await anon.get(path) { XCTAssertEqual($0.status, .unauthorized) }
            let c = try await f.login(account)
            try await c.get(path) { XCTAssertEqual($0.status, .notFound) }
            try await f.grant(account, "flow.resume", customer: tenant, by: root)
            try await c.get(path) { XCTAssertEqual($0.status, .notFound) }
            try await c.post(path + "/resume", "{\"expectedRevision\":0,\"checkpointHash\":\"\(String(repeating: "0", count: 64))\",\"originalProof\":{\"objects\":[]}}") { XCTAssertEqual($0.status, .notFound) }
        }
    }
}
