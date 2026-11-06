// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
import XCTVapor
@testable import FormAuth
@testable import FormHTTP

/// The auth routes end to end over HTTP against a real DB, with the synthetic PoC vectors.
final class AuthHTTPTests: XCTestCase {
    private let base = "admin/api/v1/auth"
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private struct FakePasswords: PasswordVerifier {
        func verify(password: String, hash: String?) async -> Bool { hash != nil && password == "correct horse" }
    }
    private struct C: Decodable { let c: Int }

    private struct Client {
        let app: Application; let origin: String
        var cookie: String? = nil
        var csrf: String? = nil

        func headers(csrf useCSRF: Bool = true, origin useOrigin: Bool = true, ip: String = "203.0.113.9", json: Bool = true) -> HTTPHeaders {
            var h = HTTPHeaders()
            if let cookie { h.add(name: .cookie, value: cookie) }
            if useCSRF, let csrf { h.add(name: "X-CSRF-Token", value: csrf) }
            if useOrigin { h.add(name: "Origin", value: origin) }
            h.add(name: "X-Test-IP", value: ip)
            if json { h.contentType = .json }
            return h
        }
    }

    private func cookieValue(_ res: XCTHTTPResponse) -> String? {
        res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }
    }

    private func decodeJSON(_ res: XCTHTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(buffer: res.body))) as? [String: Any] ?? [:]
    }

    private func loadVectors() throws -> VectorFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private func withApp(loginBudget: Int = 1000, _ body: (DBFixture, VectorFile, Client) async throws -> Void) async throws {
        let vectors = try loadVectors()
        try await DBFixture.with { f in
            let account = UUID(uuidString: vectors.userHandleText)!
            try await f.sql.raw("""
                INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
                VALUES (\(bind: DB.bin(account)), 'vector-user', 'stored', 1, 0, 4, '2026-10-30 12:00:00.000000')
                """).run()
            for (_, k) in vectors.keys {
                try await f.sql.raw("""
                    INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
                    VALUES (\(bind: Blob(Data(base64URLEncoded: k.credentialId)!)), \(bind: DB.bin(account)), \(bind: Blob(Data(vectors.userHandleText.utf8))),
                      \(bind: Blob(Data(k.publicKeyPem.utf8))), 'pem-spki', \(bind: k.alg), 0, 'v', \(bind: vectors.rpId), '2026-10-30 12:00:00.000000')
                    """).run()
            }
            try HTTPSetup.configure(f.app)
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: vectors.rpId, origin: vectors.origin),
                                 clientIP: { $0.headers.first(name: "X-Test-IP") ?? "unknown" })
            cfg.secondFactorRequired = true
            cfg.loginBudget = (loginBudget, 60)
            FormAuth.register(f.app, config: cfg, keys: key, passwords: FakePasswords())
            try await body(f, vectors, Client(app: f.app, origin: vectors.origin))
        }
    }

    private func session(_ c: inout Client) async throws {
        try await c.app.test(.GET, "\(base)/session", headers: c.headers(json: false)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            c.cookie = cookieValue(res)
            c.csrf = decodeJSON(res)["csrfToken"] as? String
        }
    }

    /// options + verify for one vector; returns the verify response signature (status/body sans requestId/headers sans id).
    private func attempt(_ f: DBFixture, _ v: VectorFile, _ vec: VectorFile.Vector, ip: String, credentialIDOverride: String? = nil, storedCount: Int? = nil) async throws -> String {
        var c = Client(app: f.app, origin: v.origin)
        try await session(&c)
        var challengeID = ""
        try await c.app.test(.POST, "\(base)/passkey/options", headers: c.headers(ip: ip)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            challengeID = decodeJSON(res)["challengeId"] as? String ?? ""
        }
        try await f.sql.raw("UPDATE auth_challenges SET challenge_hash = \(bind: Blob(Data(SHA256.hash(data: Data(base64URLEncoded: vec.challenge)!))))").run()
        if let storedCount { try await f.sql.raw("UPDATE passkeys SET sign_count = \(bind: storedCount)").run() }
        let cred = credentialIDOverride ?? v.keys[vec.key]!.credentialId
        let body = """
            {"challengeId":"\(challengeID)","credential":{"id":"\(cred)","rawId":"\(cred)","type":"public-key","response":{"authenticatorData":"\(vec.authenticatorData)","clientDataJSON":"\(vec.clientDataJSON)","signature":"\(vec.signature)","userHandle":"\(vec.userHandle)"}}}
            """
        var signature = ""
        try await c.app.test(.POST, "\(base)/passkey/verify", headers: c.headers(ip: ip), body: ByteBuffer(string: body)) { res async throws in
            var j = decodeJSON(res); j["requestId"] = nil
            var h = res.headers; h.remove(name: "X-Request-Id")
            signature = "\(res.status.code)|\(String(describing: j.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }))|\(h.map { "\($0.name.lowercased()):\($0.value)" }.sorted())"
        }
        return signature
    }

    func testFullLoginOverHTTP() async throws {
        try await withApp { f, v, client in
            var c = client
            // anonymous session: cookie attributes and no-store
            try await c.app.test(.GET, "\(base)/session", headers: c.headers(json: false)) { res async throws in
                XCTAssertEqual(res.status, .ok)
                let sc = res.headers[.setCookie].first ?? ""
                for attr in ["__Host-admin_session=", "Path=/", "Secure", "HttpOnly", "SameSite=Lax"] { XCTAssertTrue(sc.contains(attr), attr) }
                XCTAssertFalse(sc.contains("Domain"))
                XCTAssertEqual(res.headers.first(name: "Cache-Control"), "no-store")
                let j = decodeJSON(res)
                XCTAssertEqual(j["state"] as? String, "anonymous")
                c.cookie = cookieValue(res); c.csrf = j["csrfToken"] as? String
            }
            // a second GET with the cookie returns the same session and no new cookie
            try await c.app.test(.GET, "\(base)/session", headers: c.headers(json: false)) { res async throws in
                XCTAssertNil(res.headers[.setCookie].first)
                XCTAssertEqual(decodeJSON(res)["csrfToken"] as? String, c.csrf)
            }
            // CSRF/Origin are enforced and do not count as failures
            for h in [c.headers(csrf: false), c.headers(origin: false)] {
                try await c.app.test(.POST, "\(base)/passkey/options", headers: h) { res async throws in
                    XCTAssertEqual(res.status, .forbidden)
                    XCTAssertEqual(decodeJSON(res)["code"] as? String, "csrf_invalid")
                }
            }
            var evilOrigin = c.headers(); evilOrigin.replaceOrAdd(name: "Origin", value: v.origin + ".evil.test")
            try await c.app.test(.POST, "\(base)/passkey/options", headers: evilOrigin) { res async throws in XCTAssertEqual(res.status, .forbidden) }
            // options
            let vec = try XCTUnwrap(v.vectors.first { $0.name == "es256_ok_counter_0_0" })
            var challengeID = ""
            try await c.app.test(.POST, "\(base)/passkey/options", headers: c.headers()) { res async throws in
                XCTAssertEqual(res.status, .ok)
                let j = decodeJSON(res)
                challengeID = j["challengeId"] as? String ?? ""
                let pk = j["publicKey"] as? [String: Any] ?? [:]
                XCTAssertEqual(pk["rpId"] as? String, v.rpId)
                XCTAssertEqual(pk["userVerification"] as? String, "required")
                XCTAssertEqual((pk["allowCredentials"] as? [Any])?.count, 0)
                XCTAssertEqual(Data(base64URLEncoded: pk["challenge"] as? String ?? "")?.count, 32)
            }
            try await f.sql.raw("UPDATE auth_challenges SET challenge_hash = \(bind: Blob(Data(SHA256.hash(data: Data(base64URLEncoded: vec.challenge)!))))").run()
            let cred = v.keys[vec.key]!.credentialId
            let body = """
                {"challengeId":"\(challengeID)","credential":{"id":"\(cred)","rawId":"\(cred)","type":"public-key","response":{"authenticatorData":"\(vec.authenticatorData)","clientDataJSON":"\(vec.clientDataJSON)","signature":"\(vec.signature)","userHandle":"\(vec.userHandle)"}}}
                """
            var anonCookie = c.cookie
            try await c.app.test(.POST, "\(base)/passkey/verify", headers: c.headers(), body: ByteBuffer(string: body)) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(decodeJSON(res)["state"] as? String, "factor_pending")
                c.cookie = cookieValue(res)
                XCTAssertNotEqual(c.cookie, anonCookie)
                c.csrf = decodeJSON(res)["csrfToken"] as? String
            }
            anonCookie = nil
            // wrong then right password
            let pw = { (p: String) in "{\"method\":\"password\",\"password\":\"\(p)\"}" }
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: pw("nope"))) { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(decodeJSON(res)["code"] as? String, "authentication_failed")
            }
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: pw("correct horse"))) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(decodeJSON(res)["state"] as? String, "authenticated")
                XCTAssertNotNil(decodeJSON(res)["subjectId"])
                c.cookie = cookieValue(res); c.csrf = decodeJSON(res)["csrfToken"] as? String
            }
            // logout revokes
            let before = c.cookie
            try await c.app.test(.POST, "\(base)/logout", headers: c.headers(json: false)) { res async throws in
                XCTAssertEqual(res.status, .noContent)
                XCTAssertTrue((res.headers[.setCookie].first ?? "").contains("Max-Age=0"))
            }
            c.cookie = before
            try await c.app.test(.POST, "\(base)/logout", headers: c.headers(json: false)) { res async throws in XCTAssertEqual(res.status, .unauthorized) }
        }
    }

    func testEveryLoginFailureLooksTheSameOverHTTP() async throws {
        try await withApp { f, v, _ in
            var seen: [String: [String]] = [:]
            var n = 0
            for vec in v.vectors where vec.expect != "ok" {
                n += 1
                let sig = try await attempt(f, v, vec, ip: "198.51.100.\(n)", storedCount: Int(vec.storedSignCount))
                seen[sig, default: []].append(vec.name)
            }
            // unknown credential, bad key id
            n += 1
            let okVec = try XCTUnwrap(v.vectors.first { $0.name == "es256_ok_counter_0_0" })
            let unknown = try await attempt(f, v, okVec, ip: "198.51.100.\(n)", credentialIDOverride: "AAECAwQ")
            seen[unknown, default: []].append("unknown-credential")
            XCTAssertEqual(seen.count, 1, "responses differ: \(seen.mapValues { $0.count }) \(seen.keys)")
            XCTAssertTrue(seen.keys.first?.hasPrefix("401|") ?? false)
            XCTAssertGreaterThan(n, 17)
        }
    }

    func testBudgetsAndRequestValidation() async throws {
        try await withApp(loginBudget: 3) { f, v, client in
            var c = client
            try await session(&c)
            for _ in 1...3 {
                try await c.app.test(.POST, "\(base)/passkey/options", headers: c.headers()) { res async throws in XCTAssertEqual(res.status, .ok) }
            }
            try await c.app.test(.POST, "\(base)/passkey/options", headers: c.headers()) { res async throws in
                XCTAssertEqual(res.status, .tooManyRequests)
                XCTAssertGreaterThanOrEqual(Int(res.headers.first(name: "Retry-After") ?? "0") ?? 0, 1)
                XCTAssertEqual(decodeJSON(res)["code"] as? String, "rate_limited")
            }
            // another IP is unaffected
            try await c.app.test(.POST, "\(base)/passkey/options", headers: c.headers(ip: "198.51.100.77")) { res async throws in XCTAssertEqual(res.status, .ok) }
        }
        try await withApp { f, v, client in
            var c = client
            try await session(&c)
            // no cookie -> 401 (not a failure count)
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: Client(app: c.app, origin: v.origin).headers(), body: ByteBuffer(string: "{}")) { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(decodeJSON(res)["code"] as? String, "unauthenticated")
            }
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(json: false), body: ByteBuffer(string: "x")) { res async throws in XCTAssertEqual(res.status, .unsupportedMediaType) }
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: "{not json")) { res async throws in XCTAssertEqual(res.status, .badRequest) }
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: "{\"method\":\"totp\",\"password\":\"x\"}")) { res async throws in XCTAssertEqual(res.status, .badRequest) }
            let huge = "{\"method\":\"password\",\"password\":\"" + String(repeating: "a", count: 20_000) + "\"}"
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: huge)) { res async throws in XCTAssertEqual(res.status, .payloadTooLarge) }
            // anonymous session cannot use the second factor
            try await c.app.test(.POST, "\(base)/second-factor/password", headers: c.headers(), body: ByteBuffer(string: "{\"method\":\"password\",\"password\":\"correct horse\"}")) { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                XCTAssertEqual(decodeJSON(res)["code"] as? String, "authentication_failed")
            }
        }
    }
}
