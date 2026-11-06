// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormAuth
import FormCore
import FormPersistence
import FormStorage
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// These cases need MariaDB; absence of the integration-test environment is an explicit skip.
final class StorageLifecycleTests: XCTestCase {
    private let kid = "0123456789abcdef"
    private struct ID: Decodable { let id: Blob }
    private struct State: Decodable { let state: String }
    private struct Count: Decodable { let c: Int }
    private struct World { let customer: UUID; let form: UUID; let submission: UUID; let service: StorageService; let secrets: SecretStore }

    private actor FakeStore: ObjectStore {
        var objects: [String: Data] = [:]
        var putFails = false, deleteFails = false
        func failures(put: Bool = false, delete: Bool = false) { putFails = put; deleteFails = delete }
        func put(_ key: String, data: Data) async throws { if putFails { throw StorageError("injected_put_failure") }; objects[key] = data }
        func get(_ key: String) async throws -> Data { guard let value = objects[key] else { throw StorageError("object_missing") }; return value }
        func delete(_ key: String) async throws { if deleteFails { throw StorageError("injected_delete_failure") }; objects[key] = nil }
        func head(_ key: String) async throws -> Int? { objects[key]?.count }
    }
    private func world(_ f: AdminFixture, adapter: FakeStore? = nil) async throws -> World {
        let customer = try await f.customer(), form = try await f.form(customer: customer), submission = UUID()
        try await f.sql.raw("""
            INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(customer)), \(bind: kid), 1, \(bind: Blob(Data(repeating: 1, count: 32))), 'active', UTC_TIMESTAMP(6))
            """).run()
        try await f.sql.raw("""
            INSERT INTO submissions (id, customer_id, form_id, release_evidence, environment, state, removable, malware_scan_status)
            VALUES (\(bind: DB.bin(submission)), \(bind: DB.bin(customer)), \(bind: DB.bin(form)), 'legacy-unknown', 'production', 'accepted', 1, 'not-applicable')
            """).run()
        let secrets = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 7, count: 32)))
        let service: StorageService
        if let adapter { service = StorageService(db: f.app.db(.mysql), secrets: secrets, adapterFactory: { _, _, _, _ in adapter }) }
        else { service = StorageService(db: f.app.db(.mysql), secrets: secrets) }
        return World(customer: customer, form: form, submission: submission, service: service, secrets: secrets)
    }
    private func policy(_ f: AdminFixture, scope: String, value: String) async throws {
        try await f.sql.raw("INSERT INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at) VALUES (\(bind: scope), 'storage.policy', \(bind: value), 1, UTC_TIMESTAMP(6))").run()
    }
    private func external(_ f: AdminFixture, _ w: World) async throws -> UUID {
        let connection = UUID()
        let ref = try await w.secrets.put(Data("{\"accessKeyId\":\"testaccess\",\"secretAccessKey\":\"testsecret\"}".utf8))
        // A blocked endpoint proves that failure is durable without sending credentials or opening a connection.
        let cfg = "{\"endpoint\":\"https://127.0.0.1:1\",\"region\":\"us-east-1\",\"bucket\":\"test-bucket\",\"pathStyle\":true}"
        try await f.sql.raw("INSERT INTO connections (id, kind, name, safe_config_json, credential_ref, enabled) VALUES (\(bind: DB.bin(connection)), 's3', 'synthetic', \(bind: cfg), \(bind: ref), 1)").run()
        try await f.sql.raw("INSERT INTO customer_connections (customer_id, connection_id) VALUES (\(bind: DB.bin(w.customer)), \(bind: DB.bin(connection)))").run()
        return connection
    }
    private func insert(_ f: AdminFixture, _ w: World, role: String = "data", ordinal: Int = 0) async throws -> Blob {
        try await w.service.insert(sql: f.sql, customer: w.customer, form: w.form, submission: w.submission, role: role, ordinal: ordinal,
                                   wire: Data("synthetic-sealed-package".utf8), kid: kid, payloadHash: Data(repeating: 2, count: 32), originalBytes: 10)
        return try await f.sql.raw("SELECT id FROM stored_objects WHERE submission_id = \(bind: DB.bin(w.submission)) AND object_role = \(bind: role) AND ordinal_no = \(bind: ordinal)").first(decoding: ID.self)!.id
    }

    func testStorageDBRoundTripHashScopeAndVisibility() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), id = try await insert(f, w), key = DB.uuid(id.data)!.uuidString.lowercased()
            let store = DBObjectStore(sql: f.sql, customer: w.customer, form: w.form)
            let bytes = try await store.get(key)
            XCTAssertEqual(bytes, Data("synthetic-sealed-package".utf8))
            try await f.sql.raw("UPDATE stored_objects SET state = 'prepared' WHERE id = \(bind: id)").run()
            let absent = try await store.head(key); XCTAssertNil(absent)
            do { _ = try await store.get(key); XCTFail("Prepared object was readable") } catch let e as StorageError { XCTAssertEqual(e.code, "object_unavailable") }
            try await store.put(key, data: bytes)
            let state = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(state, "ready")
            let serviceBytes = try await w.service.read(sql: f.sql, customer: w.customer, form: w.form, object: id)
            XCTAssertEqual(serviceBytes, bytes)
            let wrongScope = DBObjectStore(sql: f.sql, customer: UUID(), form: w.form)
            let wrongHead = try await wrongScope.head(key); XCTAssertNil(wrongHead)
            do { try await wrongScope.put(key, data: bytes); XCTFail("Cross-customer write") } catch let e as StorageError { XCTAssertEqual(e.code, "object_unavailable") }
            try await f.sql.raw("UPDATE stored_objects SET ciphertext = \(bind: Blob(Data(repeating: 0, count: bytes.count))) WHERE id = \(bind: id)").run()
            do { _ = try await w.service.read(sql: f.sql, customer: w.customer, form: w.form, object: id); XCTFail("Tampering accepted") } catch let e as StorageError { XCTAssertEqual(e.code, "ciphertext_hash_mismatch") }
            try await f.sql.raw("UPDATE stored_objects SET expires_at = DATE_SUB(UTC_TIMESTAMP(6), INTERVAL 1 SECOND) WHERE id = \(bind: id)").run()
            let expired = try await store.head(key); XCTAssertNil(expired)
        }
    }

    func testStoragePolicyInheritancePreparedSpoolAndDurableFailure() async throws {
        try await AdminFixture.with { f in
            let fake = FakeStore()
            let w = try await world(f, adapter: fake), connection = try await external(f, w)
            try await policy(f, scope: "customer:\(w.customer.uuidString.lowercased())", value: "{\"connectionId\":\"\(connection)\",\"data\":true,\"attachmentThreshold\":9}")
            let inherited = try await w.service.policy(customer: w.customer, form: w.form, sql: f.sql)
            XCTAssertEqual(inherited.connectionId, connection)
            let id = try await insert(f, w)
            var state = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(state, "prepared")
            let spool = try await f.sql.raw("SELECT COUNT(*) AS c FROM storage_uploads WHERE object_id = \(bind: id)").first(decoding: Count.self)?.c
            XCTAssertEqual(spool, 1)
            do { _ = try await w.service.read(sql: f.sql, customer: w.customer, form: w.form, object: id); XCTFail("Prepared external object visible") } catch let e as StorageError { XCTAssertEqual(e.code, "object_unavailable") }
            await fake.failures(put: true)
            do { try await w.service.flush(submission: w.submission); XCTFail("Failed endpoint succeeded") } catch let e as StorageError { XCTAssertEqual(e.code, "upload_failed") }
            state = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(state, "failed")
            let retained = try await f.sql.raw("SELECT COUNT(*) AS c FROM storage_uploads WHERE object_id = \(bind: id)").first(decoding: Count.self)?.c
            XCTAssertEqual(retained, 1)
            await fake.failures()
            try await w.service.flush(submission: w.submission)
            state = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(state, "ready")
            let read = try await w.service.read(sql: f.sql, customer: w.customer, form: w.form, object: id)
            XCTAssertEqual(read, Data("synthetic-sealed-package".utf8))
            let cleared = try await f.sql.raw("SELECT COUNT(*) AS c FROM storage_uploads WHERE object_id = \(bind: id)").first(decoding: Count.self)?.c
            XCTAssertEqual(cleared, 0)
            // Threshold is strict and measures original bytes, not the larger ciphertext envelope.
            for (ordinal, original) in [9, 10].enumerated() {
                try await w.service.insert(sql: f.sql, customer: w.customer, form: w.form, submission: w.submission, role: "attachment", ordinal: ordinal,
                    wire: Data("sealed-file".utf8), kid: kid, payloadHash: Data(repeating: 3, count: 32), originalBytes: original)
            }
            struct Placement: Decodable { let backend: String; let state: String }
            let placements = try await f.sql.raw("SELECT backend, state FROM stored_objects WHERE submission_id = \(bind: DB.bin(w.submission)) AND object_role = 'attachment' ORDER BY ordinal_no").all(decoding: Placement.self)
            XCTAssertEqual(placements.map(\.backend), ["db", "s3"])
            XCTAssertEqual(placements.map(\.state), ["ready", "prepared"])
            try await w.service.flush(submission: w.submission)
            // Prepared inventory without a spool is a recoverable tracked orphan, never silently forgotten.
            try await f.sql.raw("UPDATE stored_objects SET state = 'prepared' WHERE id = \(bind: id)").run()
            try await w.service.cleanOrphans()
            let orphan = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(orphan, "failed")
            try await policy(f, scope: "form:\(w.form.uuidString.lowercased())", value: "{\"data\":false}")
            let overridden = try await w.service.policy(customer: w.customer, form: w.form, sql: f.sql)
            XCTAssertNil(overridden.connectionId); XCTAssertFalse(overridden.data)
            // Existing references remain external when defaults change.
            struct Backend: Decodable { let backend: String }
            let backend = try await f.sql.raw("SELECT backend FROM stored_objects WHERE id = \(bind: id)").first(decoding: Backend.self)?.backend
            XCTAssertEqual(backend, "s3")
        }
    }

    func testStorageDeletionFailureKeepsInventoryAndWithholdsProof() async throws {
        try await AdminFixture.with { f in
            let fake = FakeStore()
            let w = try await world(f, adapter: fake), connection = try await external(f, w)
            try await policy(f, scope: "customer:\(w.customer.uuidString.lowercased())", value: "{\"connectionId\":\"\(connection)\",\"data\":true}")
            let id = try await insert(f, w)
            try await w.service.flush(submission: w.submission)
            // Intent commits separately, before any remote deletion; a restart must still find it.
            try await f.app.db(.mysql).transaction { conn in
                try await SubmissionEraser.prepare(conn as! SQLDatabase, tenant: w.customer, form: w.form, ids: [w.submission], now: Date())
            }
            let intent = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(intent, "deleting")
            await fake.failures(delete: true)
            let pending = try await f.app.db(.mysql).transaction { conn in
                try await SubmissionEraser.erase(conn as! SQLDatabase, tenant: w.customer, form: w.form, ids: [w.submission], reason: "request", actor: nil, now: Date(), storage: w.service)
            }
            XCTAssertEqual(pending.pending, [w.submission]); XCTAssertTrue(pending.deleted.isEmpty)
            let state = try await f.sql.raw("SELECT state FROM stored_objects WHERE id = \(bind: id)").first(decoding: State.self)?.state
            XCTAssertEqual(state, "deleting")
            let evidence = try await f.sql.raw("SELECT COUNT(*) AS c FROM deletion_records WHERE subject_id = \(bind: DB.bin(w.submission))").first(decoding: Count.self)?.c
            XCTAssertEqual(evidence, 0)
            let remaining = try await f.sql.raw("SELECT COUNT(*) AS c FROM submissions WHERE id = \(bind: DB.bin(w.submission))").first(decoding: Count.self)?.c
            XCTAssertEqual(remaining, 1)
            await fake.failures()
            let confirmed = try await f.app.db(.mysql).transaction { conn in
                try await SubmissionEraser.erase(conn as! SQLDatabase, tenant: w.customer, form: w.form, ids: [w.submission], reason: "request", actor: nil, now: Date(), storage: w.service)
            }
            XCTAssertEqual(confirmed.deleted, [w.submission]); XCTAssertTrue(confirmed.pending.isEmpty)
            let proofs = try await f.sql.raw("SELECT COUNT(*) AS c FROM deletion_records WHERE subject_id = \(bind: DB.bin(w.submission))").first(decoding: Count.self)?.c
            XCTAssertEqual(proofs, 1)
            let inventory = try await f.sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE id = \(bind: id)").first(decoding: Count.self)?.c
            XCTAssertEqual(inventory, 0)
        }
    }

    func testStorageAdministrationRequiresSystemPermission() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), root = try await f.account(), reader = try await f.account()
            try await f.grant(root, "system.manage", system: true, by: root)
            let rc = try await f.login(reader), ac = try await f.login(root)
            let path = "tenants/\(w.customer)/forms/\(w.form)/storage"
            // No grant covering system: conceal existence, even for an existing form.
            try await rc.send(.PUT, path, body: "{\"data\":false}") { XCTAssertEqual($0.status, .notFound) }
            try await rc.post("tenants/\(w.customer)/connections/\(UUID())/probe", "{}") { XCTAssertEqual($0.status, .notFound) }
            // A different system grant makes the target visible, but does not authorize storage administration.
            try await f.grant(reader, "audit.read", system: true, by: root)
            let connection = try await external(f, w)
            try await rc.send(.PUT, path, body: "{\"data\":false}") { XCTAssertEqual($0.status, .forbidden) }
            try await rc.get(path) { XCTAssertEqual($0.status, .forbidden) }
            try await rc.post("tenants/\(w.customer)/connections/\(connection)/probe", "{}") { XCTAssertEqual($0.status, .forbidden) }
            // Missing/scoped-out resources remain 404, including for system administrators.
            try await rc.send(.PUT, "tenants/\(w.customer)/forms/\(UUID())/storage", body: "{\"data\":false}") { XCTAssertEqual($0.status, .notFound) }
            try await ac.post("tenants/\(w.customer)/connections/\(UUID())/probe", "{}") { XCTAssertEqual($0.status, .notFound) }
            try await ac.send(.PUT, path, body: "{\"data\":false}") { XCTAssertEqual($0.status, .noContent) }
            try await ac.send(.PUT, path, body: "{\"data\":true}") { XCTAssertEqual($0.status.code, 422) }
            try await ac.send(.PUT, "tenants/\(w.customer)/forms/\(UUID())/storage", body: "{\"data\":false}") { XCTAssertEqual($0.status, .notFound) }
        }
    }
}
