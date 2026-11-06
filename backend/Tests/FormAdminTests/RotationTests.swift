// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
@testable import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Real MariaDB/HTTP behavior. All keys and packages are synthetic test material.
final class RotationTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private struct World {
        let tenant: UUID, form: UUID, submission: UUID, user: UUID, other: UUID
        let client: TestClient, second: TestClient
        let old: Curve25519.KeyAgreement.PrivateKey, next: Curve25519.KeyAgreement.PrivateKey
        var path: String { "tenants/\(tenant)/key-rotation" }
    }
    private func json(_ object: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func b64(_ n: Int) -> String { Data(repeating: 7, count: n).base64URLString }
    private func recovery() -> [String: Any] { ["salt": b64(32), "iterations": 600000, "iv": b64(12), "wrap": b64(48)] }
    private func access(_ account: UUID) -> [String: Any] { ["accountId": account.uuidString.lowercased(), "enc": b64(32), "sealed": b64(48)] }
    private func begin(_ w: World, accounts: [UUID]? = nil) throws -> String {
        try json(["publicKey": w.next.publicKey.rawRepresentation.base64URLString, "access": (accounts ?? [w.user, w.other]).map(access), "recovery": recovery()])
    }
    private func world(_ f: AdminFixture) async throws -> World {
        let user = try await f.account(), other = try await f.account(), tenant = try await f.customer()
        let form = try await f.form(customer: tenant), submission = UUID()
        for a in [user, other] {
            for right in ["key.manage", "content.decrypt", "content.hold", "identity.manage"] { try await f.grant(a, right, customer: tenant, by: user) }
            try await f.sql.raw("INSERT INTO account_keys (account_id, public_key, created_at) VALUES (\(bind: DB.bin(a)), \(bind: Blob(Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation)), NOW(6))").run()
        }
        let c = try await f.login(user), d = try await f.login(other)
        let old = Curve25519.KeyAgreement.PrivateKey(), next = Curve25519.KeyAgreement.PrivateKey()
        let w = World(tenant: tenant, form: form, submission: submission, user: user, other: other, client: c, second: d, old: old, next: next)
        let body = try json(["publicKey": old.publicKey.rawRepresentation.base64URLString, "access": ["enc": b64(32), "sealed": b64(48)], "recovery": recovery()])
        try await c.send(.PUT, "tenants/\(tenant)/customer-key", body: body) { XCTAssertEqual($0.status, .created, text($0)) }
        let kid = try keyID(old.publicKey.rawRepresentation)
        try await c.send(.PUT, "tenants/\(tenant)/key-access/\(other)", body: json(["kid": kid, "enc": b64(32), "sealed": b64(48)])) { XCTAssertEqual($0.status, .created, text($0)) }
        try await f.sql.raw("""
            INSERT INTO submissions (id, customer_id, form_id, release_evidence, environment, state, removable, malware_scan_status)
            VALUES (\(bind: DB.bin(submission)), \(bind: DB.bin(tenant)), \(bind: DB.bin(form)), 'legacy-unknown', 'legacy-unknown', 'accepted', 1, 'none')
            """).run()
        return w
    }
    func testRevocationQueuesRotationAndBeginConsumesRequest() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            try await w.client.send(.DELETE, "tenants/\(w.tenant)/key-access/\(w.other)") { XCTAssertEqual($0.status, .noContent) }
            try await w.client.get(w.path) { XCTAssertEqual(jsonObject($0)["requested"] as? Bool, true) }
            try await w.client.send(.POST, w.path, body: begin(w, accounts: [w.user])) { XCTAssertEqual($0.status, .created) }
            try await w.client.get(w.path) { XCTAssertEqual(jsonObject($0)["requested"] as? Bool, false); XCTAssertNotNil(jsonObject($0)["retiring"]) }
        }
    }
    func testAutomaticRecipientsAreCompleteAndPinnedToCurrentAccountKeys() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            struct K: Decodable { let public_key: Blob }
            var entries: [[String: Any]] = []
            for id in [w.user, w.other] {
                let key = try await f.sql.raw("SELECT public_key FROM account_keys WHERE account_id = \(bind: DB.bin(id))").first(decoding: K.self)
                var a = access(id); a["expectedPublicKey"] = key!.public_key.data.base64URLString; entries.append(a)
            }
            func body(_ items: [[String: Any]]) throws -> String {
                try json(["publicKey": w.next.publicKey.rawRepresentation.base64URLString, "automatic": true, "access": items, "recovery": recovery()])
            }
            try await w.client.send(.POST, w.path, body: body([entries[0]])) { XCTAssertEqual($0.status, .conflict) }
            var changed = entries; changed[1]["expectedPublicKey"] = b64(32)
            try await w.client.send(.POST, w.path, body: body(changed)) { XCTAssertEqual($0.status, .conflict) }
            try await w.client.send(.POST, w.path, body: body(entries)) { XCTAssertEqual($0.status, .created, text($0)) }
        }
    }
    private func object(_ f: AdminFixture, _ w: World, role: String = "data", state: String = "ready", ordinal: Int = 0, payload: Data = Data("rotation payload".utf8)) async throws -> (UUID, PackageV2, String) {
        let id = UUID()
        let p = try PackageV2.seal(payload, recipient: w.old.publicKey.rawRepresentation)
        let hash = sha256(Data(p.wire.utf8))
        try await f.sql.raw("""
            INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, expires_at, backend, ciphertext, packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
            VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(w.tenant)), \(bind: DB.bin(w.form)), \(bind: DB.bin(w.submission)), \(bind: role), \(bind: ordinal), 0, DATE_ADD(NOW(), INTERVAL 1 HOUR), 'db', \(bind: Blob(Data(p.wire.utf8))), 'KUBUS-AEAD:2', 'hpke', \(bind: p.kid), 'raw', \(bind: Blob(hash)), \(bind: Blob(sha256(p.iv + p.ciphertext + p.tag))), \(bind: p.wire.utf8.count), \(bind: state))
            """).run()
        return (id, p, hash.hex)
    }
    private func rewrap(_ p: PackageV2, _ w: World, sym: Bool = false) throws -> PackageV2 {
        let cek: Data
        if p.wrap == "hpke" {
            cek = try HPKE.open(p.b, enc: p.a, recipient: w.old, info: Data("kubus-anfrage v2".utf8), aad: Data(p.kid.utf8))
        } else {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: w.old.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
            cek = try openGCM(p.b, key: key, nonce: p.a, aad: Data(p.kid.utf8))
        }
        let kid = try keyID(w.next.publicKey.rawRepresentation)
        let a: Data, b: Data
        if sym {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: w.next.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
            a = Data(repeating: 9, count: 12)
            b = try sealGCM(cek, key: key, nonce: a, aad: Data(kid.utf8))
        } else {
            let sealed = try HPKE.seal(cek, recipient: w.next.publicKey.rawRepresentation, info: Data("kubus-anfrage v2".utf8), aad: Data(kid.utf8))
            a = sealed.enc; b = sealed.ciphertext
        }
        return try PackageV2("KUBUS-AEAD:2|\(kid)|\(sym ? "sym" : "hpke")|\(a.base64EncodedString()):\(b.base64EncodedString())|\(p.iv.base64EncodedString())|\(p.ciphertext.base64EncodedString())|\(p.tag.base64EncodedString())")
    }
    private func putBody(_ package: PackageV2, hash: String, revision: Int = 0) throws -> String {
        try json(["expectedRevision": revision, "expectedSha256": hash, "package": package.wire])
    }

    func testRotationCASRightsPayloadInvariantAuditAndAtomicFinish() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), (id, p, hash) = try await object(f, w)
            let strangerID = try await f.account()
            let stranger = try await f.login(strangerID)
            try await stranger.post(w.path, begin(w)) { XCTAssertTrue([403, 404].contains($0.status.code)) }
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .conflict, text($0)) }
            let finish = try json(["kid": p.kid])
            try await w.client.post(w.path + "/finish", finish) { XCTAssertEqual($0.status, .conflict, text($0)) }
            let replacement = try rewrap(p, w)
            let body = try putBody(replacement, hash: hash)
            // A key manager still needs live content.decrypt on this object's form.
            try await f.sql.raw("DELETE FROM permission_assignments WHERE account_id = \(bind: DB.bin(w.user)) AND permission = 'content.decrypt'").run()
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: body) { XCTAssertEqual($0.status, .forbidden, text($0)) }
            try await f.grant(w.user, "content.decrypt", customer: w.tenant, by: w.other)
            let changedPayload = try PackageV2.seal(Data("changed".utf8), recipient: w.next.publicKey.rawRepresentation)
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: putBody(changedPayload, hash: hash)) { XCTAssertTrue([409, 422].contains($0.status.code), text($0)) }
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: putBody(replacement, hash: String(repeating: "0", count: 64))) { XCTAssertEqual($0.status, .conflict, text($0)) }
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: body) { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: body) { XCTAssertEqual($0.status, .conflict, text($0)) }
            struct R: Decodable { let revision: Int; let payload_sha256: Blob; let ciphertext: Blob }
            let storedRow = try await f.sql.raw("SELECT revision,payload_sha256,ciphertext FROM stored_objects WHERE id = \(bind: DB.bin(id))").first(decoding: R.self)
            let stored = try XCTUnwrap(storedRow)
            XCTAssertEqual(stored.revision, 1); XCTAssertEqual(stored.payload_sha256.data, sha256(p.iv + p.ciphertext + p.tag))
            XCTAssertEqual(try PackageV2(String(decoding: stored.ciphertext.data, as: UTF8.self)).open(recipient: w.next), Data("rotation payload".utf8))
            try await w.client.post(w.path + "/finish", finish) { XCTAssertEqual($0.status, .noContent, text($0)) }
            for table in ["customer_key_generations", "data_key_access", "data_key_recovery"] {
                let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table) WHERE customer_id = \(bind: DB.bin(w.tenant)) AND kid = \(bind: p.kid)").first(decoding: C.self)?.c
                XCTAssertEqual(n, 0, table)
            }
            struct A: Decodable { let action_code: String }
            let actions = try await f.sql.raw("SELECT action_code FROM audit_events WHERE customer_id = \(bind: DB.bin(w.tenant))").all(decoding: A.self).map(\.action_code)
            XCTAssertTrue(actions.contains("key.rotation.begin")); XCTAssertTrue(actions.contains("key.rotation.rewrap")); XCTAssertTrue(actions.contains("key.rotation.finish"))
        }
    }

    func testEveryRoleAndBackendStateBlocksFinishAndAppearsInPagedInventory() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            let roles = ["data", "attachment", "mail-organisation", "mail-filler", "mail-manifest", "legacy-errors", "checkpoint", "debug", "object-metadata", "statistics-metadata"]
            var ids = Set<String>()
            for (i, role) in roles.enumerated() { let (id, _, _) = try await object(f, w, role: role, state: ["prepared", "ready", "deleting", "failed"][i % 4]); ids.insert(id.uuidString.lowercased()) }
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let kid = try keyID(w.old.publicKey.rawRepresentation)
            var cursor: String?, seen = Set<String>()
            repeat {
                try await w.client.get(w.path + "/objects?kid=\(kid)&limit=3" + (cursor.map { "&after=\($0)" } ?? "")) { r async throws in
                    XCTAssertEqual(r.status, .ok, text(r))
                    let o = jsonObject(r), items = o["items"] as? [[String: Any]] ?? []
                    XCTAssertLessThanOrEqual(items.count, 3)
                    for item in items { let id = try XCTUnwrap(item["id"] as? String); XCTAssertTrue(seen.insert(id).inserted); XCTAssertEqual(item["kid"] as? String, kid); XCTAssertNotNil(item["revision"]); XCTAssertNotNil(item["ciphertext_sha256"]) }
                    cursor = o["next"] as? String
                }
            } while cursor != nil
            XCTAssertEqual(seen, ids)
            for _ in roles {
                try await w.client.post(w.path + "/finish", json(["kid": kid])) { XCTAssertEqual($0.status, .conflict, text($0)) }
                // Remove one synthetic inventory row to prove every remaining role independently blocks destruction.
                try await f.sql.raw("DELETE FROM stored_objects WHERE customer_id = \(bind: DB.bin(w.tenant)) LIMIT 1").run()
            }
            try await w.client.post(w.path + "/finish", json(["kid": kid])) { XCTAssertEqual($0.status, .noContent, text($0)) }
        }
    }

    func testLastIdentityMustCoverRetiringGenerationAndRevokeRemovesAllGenerations() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let old = try keyID(w.old.publicKey.rawRepresentation), next = try keyID(w.next.publicKey.rawRepresentation)
            // Simulate an incomplete recovery: the other administrator has only the active key.
            try await f.sql.raw("DELETE FROM data_key_access WHERE account_id = \(bind: DB.bin(w.other)) AND kid = \(bind: old)").run()
            try await w.second.send(.DELETE, "tenants/\(w.tenant)/key-access/\(w.user)") { XCTAssertEqual($0.status, .conflict, text($0)) }
            try await w.second.send(.PUT, "tenants/\(w.tenant)/members/\(w.user)/permissions", body: "{\"permissions\":[]}") { XCTAssertEqual($0.status, .conflict, text($0)) }
            // Restore the old access, then revoke the other account: both generations disappear atomically.
            try await f.sql.raw("INSERT INTO data_key_access (customer_id,kid,account_id,enc,sealed_key,granted_by,granted_at) VALUES (\(bind: DB.bin(w.tenant)), \(bind: old), \(bind: DB.bin(w.other)), \(bind: Blob(Data(repeating: 7, count: 32))), \(bind: Blob(Data(repeating: 7, count: 48))), \(bind: DB.bin(w.user)), NOW(6))").run()
            try await w.client.send(.DELETE, "tenants/\(w.tenant)/key-access/\(w.other)") { XCTAssertEqual($0.status, .noContent, text($0)) }
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE account_id = \(bind: DB.bin(w.other)) AND kid IN (\(bind: old), \(bind: next))").first(decoding: C.self)?.c
            XCTAssertEqual(n, 0)
            try await w.client.send(.DELETE, "tenants/\(w.tenant)/key-access/\(w.user)") { XCTAssertEqual($0.status, .conflict, text($0)) }
        }
    }
    func testConcurrentBeginAndRewrapHaveExactlyOneWinner() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), (id, p, hash) = try await object(f, w)
            let start = try begin(w)
            func startRequest() async throws -> Int {
                var status = 0
                try await w.client.post(w.path, start) { status = Int($0.status.code) }
                return status
            }
            async let firstStart = startRequest()
            async let secondStart = startRequest()
            let starts = try await [firstStart, secondStart]
            XCTAssertEqual(starts.sorted(), [201, 409])
            let body = try putBody(rewrap(p, w), hash: hash)
            func rewrapRequest() async throws -> Int {
                var status = 0
                try await w.client.send(.PUT, w.path + "/objects/\(id)", body: body) { status = Int($0.status.code) }
                return status
            }
            async let firstWrite = rewrapRequest()
            async let secondWrite = rewrapRequest()
            let writes = try await [firstWrite, secondWrite]
            XCTAssertEqual(writes.sorted(), [204, 409])
            let audits = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('key.rotation.begin','key.rotation.rewrap')").first(decoding: C.self)?.c
            XCTAssertEqual(audits, 2)
        }
    }

    func testHeldObjectRequiresHoldPermissionAndSymmetricReplacement() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), (id, p, hash) = try await object(f, w)
            try await f.sql.raw("UPDATE submissions SET removable = 0 WHERE id = \(bind: DB.bin(w.submission))").run()
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let url = w.path + "/objects/\(id)"
            try await w.client.send(.PUT, url, body: putBody(rewrap(p, w), hash: hash)) { XCTAssertEqual($0.status.code, 422, text($0)) }
            let replacement = try rewrap(p, w, sym: true)
            try await f.sql.raw("DELETE FROM permission_assignments WHERE account_id = \(bind: DB.bin(w.user)) AND permission = 'content.hold'").run()
            try await w.client.send(.PUT, url, body: putBody(replacement, hash: hash)) { XCTAssertEqual($0.status, .forbidden, text($0)) }
            try await f.grant(w.user, "content.hold", customer: w.tenant, by: w.other)
            try await w.client.send(.PUT, url, body: putBody(replacement, hash: hash)) { XCTAssertEqual($0.status, .noContent, text($0)) }
            XCTAssertEqual(try replacement.open(recipient: w.next), Data("rotation payload".utf8))
        }
    }

    func testSymmetricWrapCannotBeDowngradedToHPKE() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), (id, p, _) = try await object(f, w)
            let cek = try HPKE.open(p.b, enc: p.a, recipient: w.old, info: Data("kubus-anfrage v2".utf8), aad: Data(p.kid.utf8))
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: w.old.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
            let iv = Data(repeating: 8, count: 12), sealed = try sealGCM(cek, key: key, nonce: iv, aad: Data(p.kid.utf8))
            let oldSym = try PackageV2("KUBUS-AEAD:2|\(p.kid)|sym|\(iv.base64EncodedString()):\(sealed.base64EncodedString())|\(p.iv.base64EncodedString())|\(p.ciphertext.base64EncodedString())|\(p.tag.base64EncodedString())")
            let wire = Data(oldSym.wire.utf8), hash = sha256(wire)
            try await f.sql.raw("UPDATE stored_objects SET ciphertext = \(bind: Blob(wire)), ciphertext_sha256 = \(bind: Blob(hash)), wrap_kind = 'sym', byte_count = \(bind: wire.count) WHERE id = \(bind: DB.bin(id))").run()
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let url = w.path + "/objects/\(id)"
            try await w.client.send(.PUT, url, body: putBody(rewrap(oldSym, w), hash: hash.hex)) { XCTAssertEqual($0.status.code, 422, text($0)) }
            let nextSym = try rewrap(oldSym, w, sym: true)
            try await w.client.send(.PUT, url, body: putBody(nextSym, hash: hash.hex)) { XCTAssertEqual($0.status, .noContent, text($0)) }
            XCTAssertEqual(try nextSym.open(recipient: w.next), Data("rotation payload".utf8))
        }
    }

    func testAccountKeyReplacementRacingRevokeKeepsOneIdentityForEveryGeneration() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let credential = Data(repeating: 37, count: 20)
            try await f.sql.raw("""
                INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
                VALUES (\(bind: Blob(credential)), \(bind: DB.bin(w.user)), \(bind: Blob(Data(w.user.uuidString.lowercased().utf8))), \(bind: Blob(Data("pem".utf8))), 'pem-spki', -7, 0, 'synthetic', 'admin.example.test', NOW(6))
                """).run()
            // The fixture intentionally has no account wraps: this is the supported lost-wrap replacement path.
            let replacement = try json(["publicKey": Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLString, "wrap": ["credentialId": credential.base64URLString, "prfSalt": b64(32), "iv": b64(12), "wrap": b64(48)]])
            func replaceRequest() async throws -> Int {
                var status = 0
                try await w.client.send(.PUT, "me/account-key", body: replacement) { status = Int($0.status.code) }
                return status
            }
            func revokeRequest() async throws -> Int {
                var status = 0
                try await w.second.send(.DELETE, "tenants/\(w.tenant)/key-access/\(w.other)") { status = Int($0.status.code) }
                return status
            }
            async let replace = replaceRequest()
            async let revoke = revokeRequest()
            let result = try await (replace, revoke)
            XCTAssertTrue((result.0 == 201 && result.1 == 409) || (result.0 == 409 && result.1 == 204), "replacement=\(result.0), revoke=\(result.1)")
            let identities = try await f.sql.raw("SELECT COUNT(DISTINCT account_id) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(w.tenant))").first(decoding: C.self)?.c
            let accesses = try await f.sql.raw("SELECT COUNT(*) AS c FROM data_key_access WHERE customer_id = \(bind: DB.bin(w.tenant))").first(decoding: C.self)?.c
            XCTAssertEqual(identities, 1); XCTAssertEqual(accesses, 2)
            let capable = try await KeyManagementRoutes.capableIdentities(f.sql, tenant: w.tenant)
            XCTAssertEqual(capable.count, 1)
            let audit = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('key.account.replace','key.access.revoke')").first(decoding: C.self)?.c
            XCTAssertEqual(audit, 1)
        }
    }

    func testRecoveryBothGenerationsAfterAccessLossResumesRotation() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f), (id, p, hash) = try await object(f, w)
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let nextKid = try keyID(w.next.publicKey.rawRepresentation)
            try await f.sql.raw("DELETE FROM data_key_access WHERE customer_id = \(bind: DB.bin(w.tenant)) AND account_id = \(bind: DB.bin(w.user))").run()
            // No generation access survives the account-key loss. Recover and repair each exact kid.
            for kid in [p.kid, nextKid] {
                try await w.client.get("tenants/\(w.tenant)/key-recovery?kid=\(kid)") { res in
                    XCTAssertEqual(res.status, .ok, text(res))
                    let body = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as! [String: Any]
                    XCTAssertEqual(body["keyId"] as? String, kid)
                    XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                }
                try await w.client.send(.PUT, "tenants/\(w.tenant)/key-access/\(w.user)", body: json(["kid": kid, "enc": b64(32), "sealed": b64(48)])) { XCTAssertEqual($0.status, .created, text($0)) }
            }
            try await w.client.get("tenants/\(w.tenant)/key-recovery?kid=0000000000000000") { XCTAssertEqual($0.status, .notFound) }
            try await w.client.get("tenants/\(w.tenant)/key-recovery") { res in
                let body = try JSONSerialization.jsonObject(with: Data(buffer: res.body)) as! [String: Any]
                XCTAssertEqual(body["keyId"] as? String, nextKid)
            }
            try await w.client.send(.PUT, w.path + "/objects/\(id)", body: putBody(rewrap(p, w), hash: hash)) { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await w.client.post(w.path + "/finish", json(["kid": p.kid])) { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await w.client.get("tenants/\(w.tenant)/key-recovery?kid=\(p.kid)") { XCTAssertEqual($0.status, .notFound) }
        }
    }

    /// Use TCP: the in-memory tester supplies a pre-collected body and cannot detect Vapor's 16 KiB default.
    func testLargeHoldAndRewrapOverRealHTTP() async throws {
        try await AdminFixture.with { f in
            let w = try await world(f)
            let (id, p, hash) = try await object(f, w, payload: Data(repeating: 65, count: 32 * 1024))
            struct G: Decodable { let generation_id: Blob }
            let generation = try await f.sql.raw("SELECT generation_id FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(w.tenant)) AND kid = \(bind: p.kid)").first(decoding: G.self)!
            // Hold on the original generation with the same CEK, then rotate the held sym package.
            let same = World(tenant: w.tenant, form: w.form, submission: w.submission, user: w.user, other: w.other, client: w.client, second: w.second, old: w.old, next: w.old)
            let held = try rewrap(p, same, sym: true)
            let hold = try json(["held": true, "objects": [["objectId": id.uuidString, "expectedRevision": 0, "expectedSha256": hash, "sourceGenerationId": DB.uuid(generation.generation_id.data)!.uuidString, "replacementPackage": held.wire]]])
            XCTAssertGreaterThan(hold.utf8.count, 16 * 1024)
            let live = try f.app.testable(method: .running(hostname: "127.0.0.1", port: 0))
            try await live.test(.PUT, "admin/api/v1/tenants/\(w.tenant)/forms/\(w.form)/entries/\(w.submission)/hold", headers: w.client.headers(), body: ByteBuffer(string: hold)) { res async throws in XCTAssertEqual(res.status, .ok, text(res)) }
            try await w.client.post(w.path, begin(w)) { XCTAssertEqual($0.status, .created, text($0)) }
            let body = try putBody(rewrap(held, w, sym: true), hash: sha256(Data(held.wire.utf8)).hex, revision: 1)
            XCTAssertGreaterThan(body.utf8.count, 16 * 1024)
            try await live.test(.PUT, "admin/api/v1/" + w.path + "/objects/\(id)", headers: w.client.headers(), body: ByteBuffer(string: body)) { res async throws in XCTAssertEqual(res.status, .noContent, text(res)) }
        }
    }

}
