// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// Server side of the browser key management: the server stores and hands out opaque blobs, checks ownership, rights and shapes.
final class KeyManagementTests: XCTestCase {
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private func b64(_ n: Int, _ v: UInt8 = 7) -> String { Data(repeating: v, count: n).base64URLString }
    private struct C: Decodable { let c: Int }

    private func passkey(_ f: AdminFixture, _ account: UUID, _ id: UInt8) async throws -> String {
        let cred = Data(repeating: id, count: 20)
        try await f.sql.raw("""
            INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
            VALUES (\(bind: Blob(cred)), \(bind: DB.bin(account)), \(bind: Blob(Data(account.uuidString.lowercased().utf8))), \(bind: Blob(Data("pem".utf8))), 'pem-spki', -7, 0, 'k', 'admin.example.test', '2026-10-30 12:00:00.000000')
            """).run()
        return cred.base64URLString
    }
    private func wrap(_ cred: String) -> String { "{\"credentialId\":\"\(cred)\",\"prfSalt\":\"\(b64(32, 1))\",\"iv\":\"\(b64(12, 2))\",\"wrap\":\"\(b64(48, 3))\"}" }
    private func pub() -> String { Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLString }

    func testAccountKeyWrapsDataAccessAndRecovery() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), u = try await f.account(), v = try await f.account(), w = try await f.account(), stranger = try await f.account()
            let tenant = try await f.customer()
            for a in [u, v, w] { for r in ["form.read", "key.manage"] { try await f.grant(a, r, customer: tenant, by: root) } }
            let cu = try await f.login(u), cv = try await f.login(v), cw = try await f.login(w), cs = try await f.login(stranger)
            let credU = try await passkey(f, u, 1), credU2 = try await passkey(f, u, 2), credV = try await passkey(f, v, 3), credS = try await passkey(f, stranger, 9)

            // empty bundle
            try await cu.get("me/key-bundle") { res async throws in
                XCTAssertEqual(res.status, .ok); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertTrue(obj(res)["accountPublicKey"] is NSNull); XCTAssertEqual((obj(res)["wraps"] as? [Any])?.count, 0)
                XCTAssertEqual(obj(res)["rpId"] as? String, "admin.example.test")
            }
            // account key: low-order key, foreign credential, malformed wrap are refused
            let low = Data([1] + [UInt8](repeating: 0, count: 31)).base64URLString
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(low)\",\"wrap\":\(wrap(credU))}") { XCTAssertEqual($0.status.code, 422) }
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(credS))}") { XCTAssertEqual($0.status.code, 422) }
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":{\"credentialId\":\"\(credU)\",\"prfSalt\":\"\(b64(31))\",\"iv\":\"\(b64(12))\",\"wrap\":\"\(b64(48))\"}}") { XCTAssertEqual($0.status.code, 422) }
            // before an account key exists a further wrap cannot be added
            try await cu.send(.POST, "me/account-key/wraps", body: wrap(credU2)) { XCTAssertEqual($0.status.code, 422) }
            let pkU = pub()
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pkU)\",\"wrap\":\(wrap(credU))}") { XCTAssertEqual($0.status, .created, text($0)) }
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(credU2))}") { XCTAssertEqual($0.status, .conflict) }
            try await cu.send(.POST, "me/account-key/wraps", body: wrap(credU2)) { XCTAssertEqual($0.status, .created, text($0)) }
            try await cu.send(.POST, "me/account-key/wraps", body: wrap(credU2)) { XCTAssertEqual($0.status, .conflict) }      // never overwritten
            try await cu.send(.POST, "me/account-key/wraps", body: wrap(credS)) { XCTAssertEqual($0.status.code, 422) }        // not this account's passkey
            try await cu.get("me/key-bundle") { res async throws in
                XCTAssertEqual(obj(res)["accountPublicKey"] as? String, pkU); XCTAssertEqual((obj(res)["wraps"] as? [Any])?.count, 2)
            }
            // customer key with access + recovery, both or neither; recovery iterations are fixed
            let ck = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64URLString
            let access = "{\"enc\":\"\(b64(32))\",\"sealed\":\"\(b64(48))\"}"
            func recovery(_ it: Int) -> String { "{\"salt\":\"\(b64(32))\",\"iterations\":\(it),\"iv\":\"\(b64(12))\",\"wrap\":\"\(b64(48))\"}" }
            try await cu.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(ck)\",\"access\":\(access)}") { XCTAssertEqual($0.status.code, 422) }
            try await cu.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(ck)\",\"access\":\(access),\"recovery\":\(recovery(1000))}") { XCTAssertEqual($0.status.code, 422) }
            // an account without account key cannot register a customer key with access
            try await cv.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(ck)\",\"access\":\(access),\"recovery\":\(recovery(600000))}") { XCTAssertEqual($0.status.code, 422) }
            try await cu.send(.PUT, "tenants/\(tenant)/customer-key", body: "{\"publicKey\":\"\(ck)\",\"access\":\(access),\"recovery\":\(recovery(600000))}") { XCTAssertEqual($0.status, .created, text($0)) }
            let kid = try keyIDOf(ck)
            try await cu.get("me/key-bundle") { res async throws in
                let a = (obj(res)["access"] as? [[String: Any]]) ?? []
                XCTAssertEqual(a.count, 1); XCTAssertEqual(a.first?["kid"] as? String, kid); XCTAssertEqual(a.first?["tenantId"] as? String, tenant.uuidString.lowercased())
            }

            // granting: V has no account key yet -> 422; W has none either; the granter must hold access itself
            let grant = "{\"kid\":\"\(kid)\",\"enc\":\"\(b64(32, 5))\",\"sealed\":\"\(b64(48, 6))\"}"
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status.code, 422) }
            try await cv.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(credV))}") { XCTAssertEqual($0.status, .created) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: "{\"kid\":\"\(kid)\",\"enc\":\"\(b64(31))\",\"sealed\":\"\(b64(48))\"}") { XCTAssertEqual($0.status.code, 422) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: "{\"kid\":\"0000000000000000\",\"enc\":\"\(b64(32))\",\"sealed\":\"\(b64(48))\"}") { XCTAssertEqual($0.status.code, 422) }   // not the active generation
            try await cw.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .forbidden) }            // key.manage but no access of its own
            try await cs.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .notFound) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(stranger)", body: grant) { XCTAssertEqual($0.status.code, 422) }     // no key / no rights in this customer
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .created, text($0)) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .conflict) }            // foreign access is never replaced
            try await cv.get("me/key-bundle") { res async throws in XCTAssertEqual((obj(res)["access"] as? [Any])?.count, 1) }
            // candidates: only accounts with an account key AND a right in this customer, with their public key and access state
            try await cu.get("tenants/\(tenant)/key-candidates") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res))
                let items = (obj(res)["items"] as? [[String: Any]]) ?? []
                XCTAssertEqual(Set(items.compactMap { $0["accountId"] as? String }), [u.uuidString.lowercased(), v.uuidString.lowercased()])   // w has no account key, stranger no right
                XCTAssertEqual(items.first { $0["accountId"] as? String == v.uuidString.lowercased() }?["hasAccess"] as? Bool, true)
                XCTAssertEqual(items.first { $0["accountId"] as? String == u.uuidString.lowercased() }?["publicKey"] as? String, pkU)
            }
            try await cs.get("tenants/\(tenant)/key-candidates") { XCTAssertEqual($0.status, .notFound) }
            // self-repair (recovery): the own access row may be replaced, a foreign one never
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: grant) { XCTAssertEqual($0.status, .created, text($0)) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .conflict) }
            let repaired = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'key.access.repair'").first(decoding: C.self)?.c
            XCTAssertEqual(repaired, 1)
            // lost every passkey: the account key can be replaced, but only then; its old accesses are dropped with it
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(credU2))}") { XCTAssertEqual($0.status, .conflict) }
            try await f.sql.raw("DELETE FROM account_key_wraps WHERE account_id = \(bind: DB.bin(u))").run()
            let pkU2 = pub()
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pkU2)\",\"wrap\":\(wrap(credU2))}") { XCTAssertEqual($0.status, .created, text($0)) }
            try await cu.get("me/key-bundle") { res async throws in
                XCTAssertEqual(obj(res)["accountPublicKey"] as? String, pkU2); XCTAssertEqual((obj(res)["access"] as? [Any])?.count, 0); XCTAssertEqual((obj(res)["wraps"] as? [Any])?.count, 1)
            }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: grant) { XCTAssertEqual($0.status, .created, text($0)) }   // after the recovery
            // withdrawal: rights and existence are checked, the last capable identity (access + key.manage) is protected
            try await cs.send(.DELETE, "tenants/\(tenant)/key-access/\(v)") { XCTAssertEqual($0.status, .notFound) }
            try await cw.send(.DELETE, "tenants/\(tenant)/key-access/\(w)") { XCTAssertEqual($0.status, .notFound) }              // no access row
            try await cu.send(.DELETE, "tenants/\(tenant)/key-access/\(v)") { XCTAssertEqual($0.status, .noContent, text($0)) }   // u stays capable
            try await cu.send(.DELETE, "tenants/\(tenant)/key-access/\(u)") { XCTAssertEqual($0.status, .conflict) }               // now u is the last one
            let left = try await f.sql.raw("SELECT COUNT(*) AS c FROM data_key_access").first(decoding: C.self)?.c
            XCTAssertEqual(left, 1)
            let revoked = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'key.access.revoke'").first(decoding: C.self)?.c
            XCTAssertEqual(revoked, 1)
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(v)", body: grant) { XCTAssertEqual($0.status, .created) }       // can be granted again
            // access disappears from the bundle when the right in the customer is gone (live check)
            try await f.sql.raw("DELETE FROM permission_assignments WHERE account_id = \(bind: DB.bin(v))").run()
            try await cv.get("me/key-bundle") { res async throws in XCTAssertEqual((obj(res)["access"] as? [Any])?.count, 0) }

            // recovery record: key.manage + fresh login, audited, no-store; others are refused
            try await cu.get("tenants/\(tenant)/key-recovery") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(obj(res)["iterations"] as? Int, 600000); XCTAssertEqual(obj(res)["keyId"] as? String, kid)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
            }
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'key.recovery.read'").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)
            try await cv.get("tenants/\(tenant)/key-recovery") { XCTAssertNotEqual($0.status, .ok) }
            try await cs.get("tenants/\(tenant)/key-recovery") { XCTAssertEqual($0.status, .notFound) }
            // the server holds nothing but blobs: no column contains a private key or the recovery code by construction (opaque inputs)
        }
    }

    /// Legacy key adoption (ADR 0038): after the import a customer generation exists without any access row. The browser proves
    /// the old private key against the generation's public key and seals it to the OWN account key; the server accepts that first
    /// own access only through the existing self-repair path: key.manage + fresh login + CSRF, own account only, audited.
    func testLegacyAdoptionFirstOwnAccess() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), u = try await f.account(), w = try await f.account(), reader = try await f.account(), nokey = try await f.account()
            let tenant = try await f.customer()
            for a in [u, w, nokey] { for r in ["form.read", "key.manage"] { try await f.grant(a, r, customer: tenant, by: root) } }
            try await f.grant(reader, "form.read", customer: tenant, by: root)
            var cu = try await f.login(u)
            let cw = try await f.login(w), cr = try await f.login(reader), cn = try await f.login(nokey)
            for (client, account, id) in [(cu, u, UInt8(1)), (cw, w, 2), (cr, reader, 3)] {
                let cred = try await passkey(f, account, id)
                try await client.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(cred))}") { XCTAssertEqual($0.status, .created, text($0)) }
            }
            // imported generations (as LegacyImporter writes them): public key + kid, no access row
            let active = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, retiring = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            let kidActive = try keyIDOf(active.base64URLString), kidRetiring = try keyIDOf(retiring.base64URLString)
            for (n, pk, kid, state) in [(1, retiring, kidRetiring, "retiring"), (2, active, kidActive, "active")] {
                try await f.sql.raw("""
                    INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: kid), \(bind: n), \(bind: Blob(pk)), \(bind: state), '2023-11-14 22:13:20')
                    """).run()
            }
            func count(_ q: SQLQueryString) async throws -> Int { try await f.sql.raw(q).first(decoding: C.self)?.c ?? -1 }
            let body = { (kid: String) in "{\"kid\":\"\(kid)\",\"enc\":\"\(self.b64(32, 0x21))\",\"sealed\":\"\(self.b64(48, 0x42))\"}" }
            // the generations are visible to key.manage (the browser compares the derived public key with them)
            try await cu.get("tenants/\(tenant)/key-rotation") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res))
                XCTAssertEqual((obj(res)["active"] as? [String: Any])?["publicKey"] as? String, active.base64URLString)
                XCTAssertEqual((obj(res)["retiring"] as? [String: Any])?["kid"] as? String, kidRetiring)
            }
            try await cr.get("tenants/\(tenant)/key-rotation") { XCTAssertEqual($0.status, .forbidden) }
            // refused: no CSRF, no key.manage, foreign target without own access, unknown kid, account without account key
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kidActive), csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await cr.send(.PUT, "tenants/\(tenant)/key-access/\(reader)", body: body(kidActive)) { XCTAssertEqual($0.status, .forbidden) }
            try await cw.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kidActive)) { XCTAssertEqual($0.status, .forbidden) }
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body("0123456789abcdef")) { XCTAssertEqual($0.status.code, 422) }
            try await cn.send(.PUT, "tenants/\(tenant)/key-access/\(nokey)", body: body(kidActive)) { XCTAssertEqual($0.status.code, 422) }
            // refused: stale login (fresh authentication required)
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(u))").run()
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kidActive)) { res async throws in
                XCTAssertEqual(res.status, .forbidden); XCTAssertTrue(text(res).contains("reauthentication_required"), text(res))
            }
            let none = try await count("SELECT COUNT(*) AS c FROM data_key_access")
            XCTAssertEqual(none, 0)
            let noAudit = try await count("SELECT COUNT(*) AS c FROM audit_events WHERE action_code LIKE 'key.access.%'")
            XCTAssertEqual(noAudit, 0)
            // accepted: fresh, own account, both imported generations; the blobs are stored exactly, the actor is audited
            cu = try await f.login(u)
            for kid in [kidActive, kidRetiring] {
                try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kid)) { XCTAssertEqual($0.status, .created, text($0)) }
            }
            struct Row: Decodable { let enc: Blob; let sealed_key: Blob; let granted_by: Blob }
            let rows = try await f.sql.raw("SELECT enc, sealed_key, granted_by FROM data_key_access WHERE customer_id = \(bind: DB.bin(tenant)) AND account_id = \(bind: DB.bin(u))").all(decoding: Row.self)
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0.enc.data == Data(repeating: 0x21, count: 32) && $0.sealed_key.data == Data(repeating: 0x42, count: 48) && $0.granted_by.data == DB.bin(u).data })
            let audited = try await count("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'key.access.repair' AND actor_id = \(bind: DB.bin(u))")
            XCTAssertEqual(audited, 2)
            try await cu.get("me/key-bundle") { res async throws in
                XCTAssertEqual(Set(((obj(res)["access"] as? [[String: Any]]) ?? []).compactMap { $0["kid"] as? String }), [kidActive, kidRetiring])
            }
            // a repeated (replayed) request never multiplies access: one row per generation and account, each attempt audited
            try await cu.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kidActive)) { XCTAssertEqual($0.status, .created, text($0)) }
            let after = try await count("SELECT COUNT(*) AS c FROM data_key_access")
            XCTAssertEqual(after, 2)
            let auditedAgain = try await count("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'key.access.repair'")
            XCTAssertEqual(auditedAgain, 3)
            // u's access is never written by another account without access of its own
            try await cw.send(.PUT, "tenants/\(tenant)/key-access/\(u)", body: body(kidActive)) { XCTAssertEqual($0.status, .forbidden) }
        }
    }

    /// Unlocking against the state the migration leaves (generation imported, access not yet created): the recovery route must
    /// say WHY there is nothing to open. A missing recovery wrap of an existing generation is `recovery_missing` (404 with a code,
    /// only for callers who hold key.manage); a caller without the right still gets the plain, code-less 404 (no existence leak).
    func testImportedStateRecoveryNamesTheCause() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), u = try await f.account(), outsider = try await f.account()
            let tenant = try await f.customer()
            for r in ["form.read", "key.manage"] { try await f.grant(u, r, customer: tenant, by: root) }
            var cu = try await f.login(u)
            let co = try await f.login(outsider)
            let cred = try await passkey(f, u, 1)
            try await cu.send(.PUT, "me/account-key", body: "{\"publicKey\":\"\(pub())\",\"wrap\":\(wrap(cred))}") { XCTAssertEqual($0.status, .created, text($0)) }
            let older = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, newer = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            let kidOlder = try keyIDOf(older.base64URLString), kidNewer = try keyIDOf(newer.base64URLString)
            for (n, pk, kid, state) in [(1, older, kidOlder, "retiring"), (2, newer, kidNewer, "active")] {
                try await f.sql.raw("""
                    INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_at)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: kid), \(bind: n), \(bind: Blob(pk)), \(bind: state), '2023-11-14 22:13:20')
                    """).run()
            }
            // only the older generation carries an imported recovery wrap (the importer skips rows it cannot place)
            try await f.sql.raw("""
                INSERT INTO data_key_recovery (customer_id, kid, kdf_name, salt, iterations, iv, wrapped_key, created_at)
                VALUES (\(bind: DB.bin(tenant)), \(bind: kidOlder), 'pbkdf2-hmac-sha256', \(bind: Blob(Data(repeating: 1, count: 32))), 600000, \(bind: Blob(Data(repeating: 2, count: 12))), \(bind: Blob(Data(repeating: 3, count: 48))), '2023-11-14 22:13:20')
                """).run()
            // the active generation has none: 404 `recovery_missing` (the browser can then point to the legacy key instead)
            try await cu.get("tenants/\(tenant)/key-recovery") { res async throws in
                XCTAssertEqual(res.status, .notFound, text(res)); XCTAssertEqual(obj(res)["code"] as? String, "recovery_missing", text(res))
            }
            try await cu.get("tenants/\(tenant)/key-recovery?kid=0123456789abcdef") { res async throws in
                XCTAssertEqual(res.status, .notFound); XCTAssertEqual(obj(res)["code"] as? String, "recovery_missing")
            }
            // the older one is served by kid
            try await cu.get("tenants/\(tenant)/key-recovery?kid=\(kidOlder)") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res)); XCTAssertEqual(obj(res)["keyId"] as? String, kidOlder)
            }
            // no right in the customer: plain 404 without the cause (existence stays hidden)
            try await co.get("tenants/\(tenant)/key-recovery") { res async throws in
                XCTAssertEqual(res.status, .notFound); XCTAssertNotEqual(obj(res)["code"] as? String, "recovery_missing")
            }
            // stale login: the answer names the confirmation, it is not a silent 401/404
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(u))").run()
            try await cu.get("tenants/\(tenant)/key-recovery") { res async throws in
                XCTAssertEqual(res.status, .forbidden); XCTAssertEqual(obj(res)["code"] as? String, "reauthentication_required", text(res))
            }
            cu = try await f.login(u)
            // no access row yet for either generation: the bundle lists none, the candidates say "no access"
            try await cu.get("me/key-bundle") { res async throws in XCTAssertEqual((obj(res)["access"] as? [Any])?.count, 0) }
            try await cu.get("tenants/\(tenant)/key-candidates") { res async throws in
                let items = (obj(res)["items"] as? [[String: Any]]) ?? []
                XCTAssertEqual(items.first { $0["isSelf"] as? Bool == true }?["hasAccess"] as? Bool, false, text(res))
            }
        }
    }

    private func keyIDOf(_ publicB64: String) throws -> String {
        let pk = try XCTUnwrap(Data(base64URLString: publicB64))
        return SHA256.hash(data: pk).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
