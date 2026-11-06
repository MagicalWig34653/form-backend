// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
@testable import FormFlow

/// Real MariaDB transactions and unique indexes; no in-memory substitute for fencing tests.
final class FlowStoreTests: XCTestCase {
    private struct Row: Decodable { let state: String; let fence: UInt64; let checkpoint_json: String }
    private struct Fixture {
        let app: Application; let sql: SQLDatabase; let customer: Blob; let form: Blob; let release: Blob
        let submission: UUID; let object: UUID; let hash: Data; let now: Date
        var store: FlowStore { FlowStore(db: app.db(.mysql)) }
        func create() async throws -> UUID {
            try await app.db(.mysql).transaction { db in
                try await store.create(tx: db as! SQLDatabase, customer: customer, form: form, submission: submission,
                    release: release, checkpointObject: object, checkpointHash: hash, budgetJSON: "{\"maxSteps\":100}",
                    digest: Data(repeating: 9, count: 32), digestGeneration: 1, deadline: now.addingTimeInterval(3600), now: now)
            }
        }
    }
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"], let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh --filter Flow")
        }
        func config(_ name: String) throws -> AppConfig {
            try AppConfig(env: ["FORM_DB_HOST": env["P4A_DB_HOST"] ?? "127.0.0.1", "FORM_DB_PORT": port,
                "FORM_DB_PASSWORD": pw, "FORM_DB_USER": "root", "FORM_DB_NAME": name, "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
        }
        let name = "p6flow_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let admin = try await Application.make(.testing)
        Persistence.configure(admin, try config("p4atest"))
        let root = Persistence.sql(admin)
        try await root.raw("CREATE DATABASE \(ident: name)").run()
        let app = try await Application.make(.testing)
        do {
            Persistence.configure(app, try config(name))
            let sql = Persistence.sql(app)
            let schema = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
            _ = try await MigrationRunner(db: sql).run(schemaFile: schema)
            let customer = DB.bin(UUID()), form = DB.bin(UUID()), release = DB.bin(UUID()), submission = UUID(), object = UUID()
            let key = Curve25519.KeyAgreement.PrivateKey()
            let packet = try PackageV2.seal(Data("{\"private\":\"FLOW-SECRET-MARKER\"}".utf8), recipient: key.publicKey.rawRepresentation)
            let wire = Data(packet.wire.utf8), hash = Data(SHA256.hash(data: wire)), zeros = Blob(Data(repeating: 0, count: 32)), now = Date()
            let stamp = DB.time(now)
            // Seed only upstream dependencies under disabled FKs; every engine operation runs with FKs enabled.
            try await sql.withSession { tx in
                try await tx.raw("SET FOREIGN_KEY_CHECKS=0").run()
                do {
                    try await tx.raw("INSERT INTO customers (id,name,state,created_at) VALUES (\(bind: customer),'synthetic','active',\(bind: stamp))").run()
                    try await tx.raw("INSERT INTO forms (id,customer_id,name,active,created_at) VALUES (\(bind: form),\(bind: customer),'synthetic',1,\(bind: stamp))").run()
                    try await tx.raw("""
                        INSERT INTO releases (id,customer_id,form_id,form_version_no,workflow_id,workflow_version_no,release_version_no,dependency_manifest_json,manifest_sha256,confirmed_by,confirmed_at,confirmation_audit_id)
                        VALUES (\(bind: release),\(bind: customer),\(bind: form),1,\(bind: DB.bin(UUID())),1,1,'{}',\(bind: zeros),\(bind: DB.bin(UUID())),\(bind: stamp),\(bind: DB.bin(UUID())))
                        """).run()
                    try await tx.raw("INSERT INTO submissions (id,customer_id,form_id,release_id,release_evidence,received_at,environment,state,removable,malware_scan_status) VALUES (\(bind: DB.bin(submission)),\(bind: customer),\(bind: form),\(bind: release),'recorded',\(bind: stamp),'production','accepted',1,'none')").run()
                    try await tx.raw("""
                        INSERT INTO stored_objects (id,customer_id,form_id,submission_id,object_role,ordinal_no,revision,backend,ciphertext,packet_format,wrap_kind,kid,content_encoding,ciphertext_sha256,payload_sha256,byte_count,state)
                        VALUES (\(bind: DB.bin(object)),\(bind: customer),\(bind: form),\(bind: DB.bin(submission)),'checkpoint',0,0,'db',\(bind: Blob(wire)),'KUBUS-AEAD:2','hpke',\(bind: packet.kid),'raw',\(bind: Blob(hash)),\(bind: Blob(Data(SHA256.hash(data: packet.iv + packet.ciphertext + packet.tag)))),\(bind: wire.count),'ready')
                        """).run()
                } catch { try? await tx.raw("SET FOREIGN_KEY_CHECKS=1").run(); throw error }
                try await tx.raw("SET FOREIGN_KEY_CHECKS=1").run()
            }
            try await body(Fixture(app: app, sql: sql, customer: customer, form: form, release: release, submission: submission, object: object, hash: hash, now: now))
        } catch {
            try? await app.asyncShutdown(); try? await root.raw("DROP DATABASE IF EXISTS \(ident: name)").run(); try? await admin.asyncShutdown(); throw error
        }
        try await app.asyncShutdown(); try await root.raw("DROP DATABASE \(ident: name)").run(); try await admin.asyncShutdown()
    }

    func testTwoWorkersOnlyOneLeaseAndCrashRequiresHuman() async throws {
        try await withFixture { f in
            let id = try await f.create()
            async let a = f.store.claim(run: id, now: f.now, leaseSeconds: 10)
            async let b = f.store.claim(run: id, now: f.now, leaseSeconds: 10)
            let results = try await [a,b]
            XCTAssertEqual(results.compactMap { $0 }.count, 1)
            let lease = try XCTUnwrap(results.compactMap { $0 }.first)
            let count = try await f.store.recoverExpired(now: f.now.addingTimeInterval(11))
            XCTAssertEqual(count, 1)
            let reclaimed = try await f.store.claim(run: id, now: f.now.addingTimeInterval(12))
            XCTAssertNil(reclaimed)
            do {
                try await f.store.checkpoint(lease: lease, object: f.object, hash: f.hash, state: .complete, steps: 1, now: f.now.addingTimeInterval(12))
                XCTFail("stale worker wrote checkpoint")
            } catch FlowStore.StoreError.staleLease { }
            let r = try await f.sql.raw("SELECT state,fence,checkpoint_json FROM workflow_runs WHERE id=\(bind: DB.bin(id))").first(decoding: Row.self)
            XCTAssertEqual(r?.state, "waiting-manual")
            XCTAssertFalse(r?.checkpoint_json.contains("FLOW-SECRET-MARKER") ?? true)
        }
    }

    func testEffectBarrierIdempotencyAndUnknownOutcome() async throws {
        try await withFixture { f in
            let id = try await f.create(), claimed = try await f.store.claim(run: id, now: f.now, leaseSeconds: 10)
            let lease = try XCTUnwrap(claimed)
            let first = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            let duplicate = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            XCTAssertTrue(first.isNew); XCTAssertFalse(duplicate.isNew); XCTAssertEqual(first.id, duplicate.id)
            let began = try await f.store.beginEffect(lease: lease, effect: first.id, now: f.now)
            let beganAgain = try await f.store.beginEffect(lease: lease, effect: first.id, now: f.now)
            XCTAssertTrue(began); XCTAssertFalse(beganAgain)
            _ = try await f.store.recoverExpired(now: f.now.addingTimeInterval(11))
            struct E: Decodable { let state: String; let attempts: Int }
            let e = try await f.sql.raw("SELECT state,attempts FROM workflow_effects WHERE id=\(bind: DB.bin(first.id))").first(decoding: E.self)
            XCTAssertEqual(e?.state, "uncertain"); XCTAssertEqual(e?.attempts, 1)
            do { try await f.store.finishEffect(lease: lease, effect: first.id, confirmed: true, now: f.now.addingTimeInterval(11)); XCTFail("stale worker confirmed") }
            catch FlowStore.StoreError.staleLease { }
        }
    }

    func testConfirmedEffectIsNotRepeatedAndDuplicateRunCannotBeCreated() async throws {
        try await withFixture { f in
            let id = try await f.create(), claimed = try await f.store.claim(run: id, now: f.now)
            let lease = try XCTUnwrap(claimed)
            let effect = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            _ = try await f.store.beginEffect(lease: lease, effect: effect.id, now: f.now)
            try await f.store.finishEffect(lease: lease, effect: effect.id, confirmed: true, now: f.now)
            let repeated = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            XCTAssertEqual(repeated.state, "confirmed")
            let repeatBegin = try await f.store.beginEffect(lease: lease, effect: repeated.id, now: f.now)
            XCTAssertFalse(repeatBegin)
            do { _ = try await f.create(); XCTFail("duplicate ingest slot") } catch { XCTAssertTrue(DB.isDuplicateKey(error)) }
            try await f.store.checkpoint(lease: lease, object: f.object, hash: f.hash, state: .complete, steps: 2, now: f.now)
            let row = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            XCTAssertEqual(row?.state, "complete")
        }
    }
    func testWaitingCannotBeAutoClaimedAndResumeRequiresHumanSession() async throws {
        try await withFixture { f in
            let id = try await f.create(), claimed = try await f.store.claim(run: id, now: f.now)
            let lease = try XCTUnwrap(claimed)
            let approval = try await f.store.approval(lease: lease, node: "approval", visit: 1, expires: f.now.addingTimeInterval(600), now: f.now)
            let approvalAgain = try await f.store.approval(lease: lease, node: "approval", visit: 1, expires: f.now.addingTimeInterval(600), now: f.now)
            XCTAssertEqual(approval, approvalAgain)
            try await f.store.checkpoint(lease: lease, object: f.object, hash: f.hash, state: .waiting, steps: 1, now: f.now)
            let autoClaim = try await f.store.claim(run: id, now: f.now)
            XCTAssertNil(autoClaim)
            let row = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            var proofCalled = false
            do {
                _ = try await f.store.resume(run: id, customer: f.customer, form: f.form, session: UUID(), actor: UUID(), expectedRevision: row!.revision, checkpointHash: f.hash, now: f.now) { _ in proofCalled = true }
                XCTFail("resume without human session")
            } catch FlowStore.StoreError.blocked { }
            XCTAssertFalse(proofCalled)
            struct Count: Decodable { let n: Int }
            let consumed = try await f.sql.raw("SELECT COUNT(*) AS n FROM workflow_resumptions").first(decoding: Count.self)?.n
            XCTAssertEqual(consumed, 0)
            let unchanged = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            XCTAssertEqual(unchanged?.state, "waiting")
        }
    }

    func testHumanResumptionRechecksAuthorizationAndConsumesRevisionOnce() async throws {
        try await withFixture { f in
            let id = try await f.create(), claimed = try await f.store.claim(run: id, now: f.now)
            let lease = try XCTUnwrap(claimed)
            try await f.store.checkpoint(lease: lease, object: f.object, hash: f.hash, state: .waitingManual, steps: 1, now: f.now)
            let row = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            let actor = UUID(), session = UUID(), stamp = DB.time(f.now), expiry = DB.time(f.now.addingTimeInterval(3600))
            try await f.sql.raw("INSERT INTO accounts (id,username,password_hash,active,mcp_allowed,rights_version,created_at) VALUES (\(bind: DB.bin(actor)),\(bind: actor.uuidString),'synthetic',1,0,0,\(bind: stamp))").run()
            try await f.sql.raw("""
                INSERT INTO sessions (id,token_hash,account_id,state,auth_level,auth_method,authenticated_at,rights_version,csrf_secret_ciphertext,created_at,last_seen_at,idle_expires_at,absolute_expires_at)
                VALUES (\(bind: DB.bin(session)),\(bind: Blob(Data(repeating: 1, count: 32))),\(bind: DB.bin(actor)),'authenticated','full','passkey+password',\(bind: stamp),0,\(bind: Blob(Data(repeating: 2, count: 48))),\(bind: stamp),\(bind: stamp),\(bind: expiry),\(bind: expiry))
                """).run()
            do {
                _ = try await f.store.resume(run: id, customer: f.customer, form: f.form, session: session, actor: actor, expectedRevision: row!.revision, checkpointHash: f.hash, now: f.now) { _ in throw FlowStore.StoreError.blocked }
                XCTFail("revoked permission was accepted")
            } catch FlowStore.StoreError.blocked { }
            let resumed = try await f.store.resume(run: id, customer: f.customer, form: f.form, session: session, actor: actor, expectedRevision: row!.revision, checkpointHash: f.hash, now: f.now) { _ in }
            XCTAssertGreaterThan(resumed.fence, lease.fence)
            do {
                _ = try await f.store.resume(run: id, customer: f.customer, form: f.form, session: session, actor: actor, expectedRevision: row!.revision, checkpointHash: f.hash, now: f.now) { _ in }
                XCTFail("same human approval consumed twice")
            } catch FlowStore.StoreError.conflict { }
            struct Count: Decodable { let n: Int }
            let consumed = try await f.sql.raw("SELECT COUNT(*) AS n FROM workflow_resumptions WHERE run_id=\(bind: DB.bin(id))").first(decoding: Count.self)?.n
            XCTAssertEqual(consumed, 1)
        }
    }

    func testCrashBeforeClaimExpiresReadyHandoffWithoutAutomaticRestart() async throws {
        try await withFixture { f in
            let id = try await f.create()
            let early = try await f.store.recoverExpired(now: f.now.addingTimeInterval(299))
            XCTAssertEqual(early, 0)
            let lateClaim = try await f.store.claim(run: id, now: f.now.addingTimeInterval(301))
            XCTAssertNil(lateClaim)
            let recovered = try await f.store.recoverExpired(now: f.now.addingTimeInterval(301))
            XCTAssertEqual(recovered, 1)
            let row = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            XCTAssertEqual(row?.state, "waiting-manual")
            let retry = try await f.store.claim(run: id, now: f.now.addingTimeInterval(302))
            XCTAssertNil(retry)
        }
    }

    func testPreparedEffectSurvivesRecoveryAndCanStartUnderNewFence() async throws {
        try await withFixture { f in
            let id = try await f.create()
            let oldClaim = try await f.store.claim(run: id, now: f.now, leaseSeconds: 10)
            let old = try XCTUnwrap(oldClaim)
            let effect = try await f.store.reserveEffect(lease: old, node: "send", visit: 1, slot: "mail", now: f.now)
            _ = try await f.store.recoverExpired(now: f.now.addingTimeInterval(11))
            // Simulate the already separately tested human resume; this test isolates effect reuse across fences.
            try await f.sql.raw("UPDATE workflow_runs SET state='ready',lease_token=\(bind: DB.bin(UUID())),lease_until=\(bind: DB.time(f.now.addingTimeInterval(300))) WHERE id=\(bind: DB.bin(id))").run()
            let freshClaim = try await f.store.claim(run: id, now: f.now.addingTimeInterval(12))
            let fresh = try XCTUnwrap(freshClaim)
            let reused = try await f.store.reserveEffect(lease: fresh, node: "send", visit: 1, slot: "mail", now: f.now.addingTimeInterval(12))
            XCTAssertEqual(reused.id, effect.id); XCTAssertEqual(reused.state, "prepared"); XCTAssertFalse(reused.isNew)
            do { _ = try await f.store.beginEffect(lease: old, effect: effect.id, now: f.now.addingTimeInterval(12)); XCTFail("old fence started transport") }
            catch FlowStore.StoreError.staleLease { }
            let began = try await f.store.beginEffect(lease: fresh, effect: reused.id, now: f.now.addingTimeInterval(12))
            XCTAssertTrue(began)
        }
    }

    func testUncertainEffectReconcilesDurableSMTPAcceptance() async throws {
        try await withFixture { f in
            let id = try await f.create()
            let leaseClaim = try await f.store.claim(run: id, now: f.now)
            let lease = try XCTUnwrap(leaseClaim)
            let effect = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            _ = try await f.store.beginEffect(lease: lease, effect: effect.id, now: f.now)
            try await f.store.finishEffect(lease: lease, effect: effect.id, confirmed: false, now: f.now)
            let unknown = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            XCTAssertEqual(unknown.state, "uncertain")
            try await f.sql.raw("""
                INSERT INTO mail_deliveries (id,customer_id,form_id,submission_id,environment,mail_kind,identity_scope,effect_id,transport_kind,state,attempts,created_at,updated_at)
                VALUES (\(bind: DB.bin(UUID())),\(bind: f.customer),\(bind: f.form),\(bind: DB.bin(f.submission)),'production','organisation','synthetic',\(bind: DB.bin(effect.id)),'smtp','smtp-accepted',1,NOW(6),NOW(6))
                """).run()
            let reconciled = try await f.store.reserveEffect(lease: lease, node: "send", visit: 1, slot: "mail", now: f.now)
            XCTAssertEqual(reconciled.state, "confirmed")
            let repeated = try await f.store.beginEffect(lease: lease, effect: effect.id, now: f.now)
            XCTAssertFalse(repeated)
        }
    }

    func testWaitingDeadlineBecomesTerminalAndInvalidatesFence() async throws {
        try await withFixture { f in
            let id = try await f.create()
            let leaseClaim = try await f.store.claim(run: id, now: f.now)
            let lease = try XCTUnwrap(leaseClaim)
            try await f.store.checkpoint(lease: lease, object: f.object, hash: f.hash, state: .waiting, steps: 1, now: f.now)
            try await f.store.expireWaiting(now: f.now.addingTimeInterval(3601))
            let row = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            XCTAssertEqual(row?.state, "failed")
            try await f.store.expireWaiting(now: f.now.addingTimeInterval(3602))
            let again = try await f.store.snapshot(run: id, customer: f.customer, form: f.form)
            XCTAssertEqual(again?.revision, row?.revision)
        }
    }

}
