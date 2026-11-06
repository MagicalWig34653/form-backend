// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

final class AccountTests: XCTestCase {
    private func obj(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }
    private func text(_ r: XCTHTTPResponse) -> String { String(decoding: Data(buffer: r.body), as: UTF8.self) }
    private struct C: Decodable { let c: Int }

    func testAccountStatusLastAdminAndLiveRevocation() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), other = try await f.account(), plain = try await f.account()
            for id in [root, other] {
                try await f.grant(id, "identity.manage", system: true, by: root)
                try await f.grant(id, "system.manage", system: true, by: root)
            }
            for id in [root, other] {
                try await f.sql.raw("INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at) VALUES (\(bind: Blob(Data(id.uuidString.utf8))), \(bind: DB.bin(id)), \(bind: Blob(Data(id.uuidString.utf8))), \(bind: Blob(Data([1]))), 'pem-spki', -7, 0, 'synthetic', 'example.test', NOW(6))").run()
            }
            let cr = try await f.login(root), co = try await f.login(other), cp = try await f.login(plain)
            let path = "accounts/\(other)/status"
            try await cp.send(.PUT, path, body: "{\"active\":false}") { XCTAssertEqual($0.status, .notFound) }
            try await cr.send(.PUT, path, body: "{\"active\":false}") { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await co.get("me/passkeys") { XCTAssertEqual($0.status, .unauthorized) }
            try await cr.send(.PUT, "accounts/\(root)/status", body: "{\"active\":false}") { XCTAssertEqual($0.status, .conflict) }
            try await cr.send(.PUT, path, body: "{\"active\":true}") { XCTAssertEqual($0.status, .noContent) }
            try await co.get("me/passkeys") { XCTAssertEqual($0.status, .unauthorized, "unlock never revives a session") }
            try await cr.send(.PUT, path, body: "{\"mcpAllowed\":true}") { XCTAssertEqual($0.status, .noContent) }
            try await cr.send(.PUT, path, body: "{\"mcpAllowed\":false}") { XCTAssertEqual($0.status, .noContent) }
            try await cr.send(.PUT, path, body: "{\"mcpAllowed\":false,\"active\":true}") { XCTAssertEqual($0.status, .badRequest) }
            try await cr.send(.PUT, path, body: "{\"active\":1}") { XCTAssertEqual($0.status, .badRequest) }
            // Live authorization after rights withdrawal.
            try await f.sql.raw("UPDATE permission_assignments SET revoked_at = NOW(6) WHERE account_id = \(bind: DB.bin(root)) AND permission = 'identity.manage'").run()
            try await cr.send(.PUT, path, body: "{\"active\":false}") { XCTAssertEqual($0.status, .forbidden) }
        }
    }

    func testInternalOptionalPasswordAndFreshSelfServiceSetup() async throws {
        try await AdminFixture.with(secondFactorRequired: false) { f in
            let root = try await f.account()
            try await f.grant(root, "identity.manage", system: true, by: root)
            let current = try await f.login(root), other = try await f.login(root)
            try await current.send(.POST, "accounts", body: "{\"username\":\"passkey.only\"}") { res in
                XCTAssertEqual(res.status, .created, text(res))
            }
            struct Hash: Decodable { let password_hash: String }
            let empty = try await f.sql.raw("SELECT password_hash FROM accounts WHERE username = 'passkey.only'").first(decoding: Hash.self)
            XCTAssertEqual(empty?.password_hash, "")
            try await current.send(.PUT, "me/password", body: "{\"password\":\"too-short\"}") { XCTAssertEqual($0.status.code, 422) }
            try await current.send(.PUT, "me/password", body: "{\"password\":\"new-long-password\"}") { XCTAssertEqual($0.status, .noContent) }
            let stored = try await f.sql.raw("SELECT password_hash FROM accounts WHERE id = \(bind: DB.bin(root))").first(decoding: Hash.self)
            XCTAssertTrue(Argon2id.verify("new-long-password", encoded: stored!.password_hash))
            try await other.get("me/passkeys") { XCTAssertEqual($0.status, .unauthorized) }
            try await f.sql.raw("UPDATE sessions SET authenticated_at = '2020-01-01' WHERE revoked_at IS NULL AND account_id = \(bind: DB.bin(root))").run()
            try await current.send(.PUT, "me/password", body: "{\"password\":\"another-long-password\"}") { XCTAssertEqual($0.status, .forbidden) }
        }
    }

    func testAccountCreationRightsAndPasskeys() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), mgr = try await f.account(), other = try await f.account(), plain = try await f.account()
            let tenant = try await f.customer()
            for r in ["identity.manage", "form.read", "content.read"] { try await f.grant(root, r, system: true, by: root) }
            for r in ["identity.manage", "form.read", "content.read"] { try await f.grant(mgr, r, customer: tenant, by: root) }
            try await f.grant(other, "form.read", customer: tenant, by: root)
            let cr = try await f.login(root), cm = try await f.login(mgr), cp = try await f.login(plain)

            // account creation: system right, strong password, unique name, one-time link
            try await cm.send(.POST, "accounts", body: "{\"username\":\"neu.person\",\"password\":\"ein-langes-passwort\"}") { XCTAssertNotEqual($0.status, .created) }
            try await cr.send(.POST, "accounts", body: "{\"username\":\"neu.person\",\"password\":\"kurz\"}") { XCTAssertEqual($0.status.code, 422) }
            try await cr.send(.POST, "accounts", body: "{\"username\":\"Neu Person\",\"password\":\"ein-langes-passwort\"}") { XCTAssertEqual($0.status.code, 422) }
            var newID = ""
            try await cr.send(.POST, "accounts", body: "{\"username\":\"neu.person\",\"password\":\"ein-langes-passwort\"}") { res async throws in
                XCTAssertEqual(res.status, .created, text(res)); XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                XCTAssertTrue((obj(res)["setupLink"] as? String ?? "").contains("/setup#")); newID = obj(res)["id"] as? String ?? ""
                XCTAssertFalse(text(res).contains("ein-langes-passwort"))
            }
            try await cr.send(.POST, "accounts", body: "{\"username\":\"neu.person\",\"password\":\"ein-langes-passwort\"}") { XCTAssertEqual($0.status, .conflict) }
            let stored = try await f.sql.raw("SELECT COUNT(*) AS c FROM accounts WHERE username = 'neu.person' AND password_hash LIKE '$argon2id$%'").first(decoding: C.self)?.c
            XCTAssertEqual(stored, 1)
            let target = try XCTUnwrap(UUID(uuidString: newID))

            // members: only with account.manage for the customer
            try await cm.get("tenants/\(tenant)/members") { res async throws in
                XCTAssertEqual(res.status, .ok, text(res))
                let names = ((obj(res)["items"] as? [[String: Any]]) ?? []).compactMap { $0["username"] as? String }
                XCTAssertFalse(names.contains("neu.person"))
                XCTAssertFalse((obj(res)["assignable"] as? [String] ?? []).contains("system.manage"))
            }
            try await cp.get("tenants/\(tenant)/members") { XCTAssertEqual($0.status, .notFound) }
            // a stranger (no right in this customer yet) can only be taken in by a system-level identity manager
            try await cm.send(.PUT, "tenants/\(tenant)/members/\(target)/permissions", body: "{\"permissions\":[\"form.read\"]}") { XCTAssertEqual($0.status, .forbidden) }
            try await cr.send(.PUT, "tenants/\(tenant)/members/\(target)/permissions", body: "{\"permissions\":[]}") { XCTAssertEqual($0.status, .noContent) }
            try await cr.send(.PUT, "tenants/\(tenant)/members/\(target)/permissions", body: "{\"permissions\":[\"form.read\"]}") { XCTAssertEqual($0.status, .noContent) }   // system identity.manage may
            // grant: only rights the manager holds, never own rights, never system.manage
            let url = "tenants/\(tenant)/members/\(target)/permissions"
            try await cm.send(.PUT, url, body: "{\"permissions\":[\"form.read\",\"content.read\"]}") { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await cm.send(.PUT, url, body: "{\"permissions\":[\"form.read\",\"key.manage\"]}") { XCTAssertEqual($0.status, .forbidden) }      // not held by the manager
            try await cm.send(.PUT, url, body: "{\"permissions\":[\"system.manage\"]}") { XCTAssertEqual($0.status.code, 422) }
            try await cm.send(.PUT, url, body: "{\"permissions\":[\"nope\"]}") { XCTAssertEqual($0.status.code, 422) }
            try await cm.send(.PUT, "tenants/\(tenant)/members/\(mgr)/permissions", body: "{\"permissions\":[\"account.manage\"]}") { XCTAssertEqual($0.status, .forbidden) }
            try await cp.send(.PUT, url, body: "{\"permissions\":[]}") { XCTAssertEqual($0.status, .notFound) }
            try await cm.get("tenants/\(tenant)/members") { res async throws in
                let me = ((obj(res)["items"] as? [[String: Any]]) ?? []).first { $0["accountId"] as? String == target.uuidString.lowercased() }
                XCTAssertEqual(me?["permissions"] as? [String], ["content.read", "form.read"])
            }
            // the new account now sees the customer; removing a right takes effect at once
            try await cm.send(.PUT, url, body: "{\"permissions\":[\"form.read\"]}") { XCTAssertEqual($0.status, .noContent) }
            let live = try await f.sql.raw("SELECT COUNT(*) AS c FROM permission_assignments WHERE account_id = \(bind: DB.bin(target)) AND revoked_at IS NULL").first(decoding: C.self)?.c
            XCTAssertEqual(live, 1)
            // a manager cannot strip a right he does not hold from another account
            try await f.grant(other, "key.manage", customer: tenant, by: root)
            try await cm.send(.PUT, "tenants/\(tenant)/members/\(other)/permissions", body: "{\"permissions\":[\"form.read\"]}") { XCTAssertEqual($0.status, .forbidden) }
            let audits = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('account.create','account.permissions.set')").first(decoding: C.self)?.c
            XCTAssertEqual(audits, 4)

            // passkeys: list, never remove the last one, remove with its key wrap
            for (i, a) in [UInt8(1), 2].enumerated() {
                try await f.sql.raw("""
                    INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
                    VALUES (\(bind: Blob(Data(repeating: a, count: 20))), \(bind: DB.bin(mgr)), \(bind: Blob(Data(mgr.uuidString.lowercased().utf8))), \(bind: Blob(Data("pem".utf8))), 'pem-spki', -7, 0, \(bind: "key \(i)"), 'admin.example.test', '2026-10-30 12:00:00.000000')
                    """).run()
            }
            let victim = try await f.login(mgr)
            let c1 = Data(repeating: 1, count: 20).base64URLString, c2 = Data(repeating: 2, count: 20).base64URLString
            try await cm.get("me/passkeys") { res async throws in XCTAssertEqual((obj(res)["items"] as? [Any])?.count, 2) }
            try await cm.send(.DELETE, "me/passkeys/\(Data(repeating: 9, count: 20).base64URLString)") { XCTAssertEqual($0.status, .notFound) }
            try await cm.send(.DELETE, "me/passkeys/\(c1)") { XCTAssertEqual($0.status, .noContent, text($0)) }
            try await victim.get("me/passkeys") { XCTAssertEqual($0.status, .unauthorized) }   // the other session ended with the removal
            try await cm.get("me/passkeys") { XCTAssertEqual($0.status, .ok) }
            try await cm.send(.DELETE, "me/passkeys/\(c2)") { XCTAssertEqual($0.status.code, 422) }
            try await cp.send(.DELETE, "me/passkeys/\(c2)") { XCTAssertEqual($0.status, .notFound) }
            let removed = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'passkey.remove'").first(decoding: C.self)?.c
            XCTAssertEqual(removed, 1)
        }
    }
}
