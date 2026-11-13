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

/// First administrator -> enrollment link -> passkey registration over HTTP -> login with exactly that key.
final class EnrollmentHTTPTests: XCTestCase {
    private let base = "admin/api/v1/auth"
    private let origin = "https://admin.example.test", rpID = "admin.example.test"
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private let password = "correct horse battery"
    private struct C: Decodable { let c: Int }

    private final class Clock: @unchecked Sendable { var t = Date(); func now() -> Date { t } }

    private struct Browser {
        let app: Application; let origin: String
        var cookie: String? = nil, csrf: String? = nil
        func headers() -> HTTPHeaders {
            var h = HTTPHeaders()
            if let cookie { h.add(name: .cookie, value: cookie) }
            if let csrf { h.add(name: "X-CSRF-Token", value: csrf) }
            h.add(name: "Origin", value: origin); h.add(name: "X-Test-IP", value: "203.0.113.9"); h.contentType = .json
            return h
        }
        mutating func newSession() async throws {
            var c = self
            var h = headers(); h.remove(name: .cookie); h.remove(name: "X-CSRF-Token")   // always a brand-new session
            try await app.test(.GET, "admin/api/v1/auth/session", headers: h) { res async throws in
                c.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }
                c.csrf = (try? JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])?["csrfToken"] as? String
            }
            self = c
        }
        func post(_ path: String, _ body: [String: Any], _ check: (XCTHTTPResponse) async throws -> Void) async throws {
            let data = try JSONSerialization.data(withJSONObject: body)
            try await app.test(.POST, "admin/api/v1/auth/\(path)", headers: headers(), body: ByteBuffer(data: data), afterResponse: check)
        }
    }

    private func json(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }

    private func withApp(_ body: (DBFixture, Browser, Clock) async throws -> Void) async throws {
        try await DBFixture.with { f in
            try HTTPSetup.configure(f.app)
            let clock = Clock()
            // These tests simulate "stale but still signed in" by advancing the clock by 301 s, so they pin the window to 5 minutes
            // (the default is 30 min, and an authenticated session already idles out after 30 min).
            try await SystemSettings.write(f.app.db(.mysql) as! SQLDatabase, key: "auth.freshLoginMinutes", value: "5", at: DB.time(Date()))
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: rpID, origin: origin), clientIP: { $0.headers.first(name: "X-Test-IP") ?? "unknown" })
            cfg.secondFactorRequired = true
            cfg.requestBudget = (100_000, 60); cfg.loginBudget = (100_000, 60)
            FormAuth.register(f.app, config: cfg, keys: key, now: { clock.now() })
            try await body(f, Browser(app: f.app, origin: origin), clock)
        }
    }

    private func creationChallenge(_ res: XCTHTTPResponse) -> (id: String, challenge: Data)? {
        guard let pk = json(res)["publicKey"] as? [String: Any], let id = json(res)["challengeId"] as? String, let c = pk["challenge"] as? String, let d = Data(base64URLEncoded: c) else { return nil }
        return (id, d)
    }

    private func registerBody(_ a: SyntheticAuthenticator, challengeID: String, challenge: Data, token: String?, label: String = "Test-Gerät") -> [String: Any] {
        let (cd, att) = a.registration(challenge: challenge)
        var b: [String: Any] = ["challengeId": challengeID, "label": label, "credential": ["id": a.credentialID.base64URL, "rawId": a.credentialID.base64URL, "type": "public-key",
                                "response": ["attestationObject": att.base64URL, "clientDataJSON": cd.base64URL]]]
        if let token { b["token"] = token }
        return b
    }

    /// Passkey login with a synthetic authenticator, then the password. Returns the authenticated browser.
    private func login(_ a: SyntheticAuthenticator, _ f: DBFixture, as b: Browser) async throws -> Browser {
        var br = b
        try await br.newSession()
        var ch: (id: String, challenge: Data)?
        try await br.post("passkey/options", [:]) { ch = creationChallenge($0) }
        let c = try XCTUnwrap(ch)
        let asr = a.assertion(challenge: c.challenge)
        var next = br
        try await br.post("passkey/verify", ["challengeId": c.id, "credential": ["id": a.credentialID.base64URL, "rawId": a.credentialID.base64URL, "type": "public-key",
            "response": ["authenticatorData": asr.authenticatorData.base64URL, "clientDataJSON": asr.clientDataJSON.base64URL, "signature": asr.signature.base64URL,
                         "userHandle": Data(try await userHandle(f).utf8).base64URL]]]) { res async throws in
            XCTAssertEqual(res.status, .ok, String(decoding: Data(buffer: res.body), as: UTF8.self))
            XCTAssertEqual(json(res)["state"] as? String, "factor_pending")
            next.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }; next.csrf = json(res)["csrfToken"] as? String
        }
        try await next.post("second-factor/password", ["method": "password", "password": password]) { res async throws in
            XCTAssertEqual(json(res)["state"] as? String, "authenticated")
            next.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }; next.csrf = json(res)["csrfToken"] as? String
        }
        return next
    }

    private func userHandle(_ f: DBFixture) async throws -> String {
        struct R: Decodable { let id: Blob }
        let r = try await f.sql.raw("SELECT id FROM accounts LIMIT 1").first(decoding: R.self)
        return DB.uuid(try XCTUnwrap(r).id.data)!.uuidString.lowercased()
    }

    func testBootstrapEnrollRegisterThenLoginWithTheRegisteredKeyForAllAlgorithms() async throws {
        for kind in [SyntheticAuthenticator.Kind.es256, .eddsa, .rs256] {
            try await withApp { f, browser, clock in
                let db = f.app.db(.mysql)
                let (account, token) = try await Bootstrap.createFirstAdmin(db: db, username: "admin", password: password, now: clock.now())
                // all catalog permissions with system scope
                let grants = try await PermissionService(sql: f.sql).grants(account: account)
                XCTAssertEqual(Set(grants.map(\.permission)), PermissionCatalog.all)
                XCTAssertTrue(grants.allSatisfy { $0.scope == .system })
                // the token is only stored hashed
                let plain = try await f.sql.raw("SELECT COUNT(*) AS c FROM account_enrollments WHERE token_hash = \(bind: Blob(Data(token.utf8)))").first(decoding: C.self)?.c
                XCTAssertEqual(plain, 0)

                let a = SyntheticAuthenticator(kind, rpID: rpID, origin: origin)
                var br = browser
                try await br.newSession()
                var ch: (id: String, challenge: Data)?
                try await br.post("enrollment/options", ["token": token]) { res async throws in
                    XCTAssertEqual(res.status, .ok); ch = creationChallenge(res)
                    let pk = json(res)["publicKey"] as? [String: Any] ?? [:]
                    XCTAssertEqual((pk["rp"] as? [String: Any])?["id"] as? String, rpID)
                    XCTAssertEqual((pk["authenticatorSelection"] as? [String: Any])?["userVerification"] as? String, "required")
                    XCTAssertEqual(pk["attestation"] as? String, "none")
                    XCTAssertEqual((pk["pubKeyCredParams"] as? [[String: Any]])?.compactMap { $0["alg"] as? Int }, [-7, -8, -257])
                    XCTAssertEqual(Data(base64URLEncoded: ((pk["user"] as? [String: Any])?["id"] as? String) ?? ""), Data(account.uuidString.lowercased().utf8))
                }
                let c = try XCTUnwrap(ch)
                try await br.post("enrollment/verify", registerBody(a, challengeID: c.id, challenge: c.challenge, token: token)) { res async throws in
                    XCTAssertEqual(res.status, .ok, String(decoding: Data(buffer: res.body), as: UTF8.self)); XCTAssertEqual(json(res)["status"] as? String, "registered")
                }
                // the token is single use, the challenge too
                var again = br
                try await again.newSession()
                try await again.post("enrollment/options", ["token": token]) { XCTAssertEqual($0.status.code, 422); XCTAssertEqual(json($0)["code"] as? String, "registration_failed") }
                // the passkey row has the legacy-compatible shape
                struct P: Decodable { let public_key_encoding: String; let cose_algorithm: Int; let user_handle: Blob; let sign_count: Int; let label: String; let rp_id: String }
                let p = try await f.sql.raw("SELECT public_key_encoding, cose_algorithm, user_handle, sign_count, label, rp_id FROM passkeys").first(decoding: P.self)
                XCTAssertEqual(p?.public_key_encoding, "pem-spki"); XCTAssertEqual(p?.label, "Test-Gerät"); XCTAssertEqual(p?.rp_id, rpID); XCTAssertEqual(p?.sign_count, 0)
                XCTAssertEqual(p.map { String(decoding: $0.user_handle.data, as: UTF8.self) }, account.uuidString.lowercased())
                // and now the full login works with exactly that key (passkey + password)
                let authed = try await login(a, f, as: browser)
                XCTAssertNotNil(authed.cookie)
                // an audit event exists
                let au = try await f.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code IN ('account.bootstrap','passkey.register')").first(decoding: C.self)?.c
                XCTAssertEqual(au, 2)
            }
        }
    }

    func testEveryEnrollmentRefusalLooksTheSame() async throws {
        try await withApp { f, browser, clock in
            let db = f.app.db(.mysql)
            let (account, token) = try await Bootstrap.createFirstAdmin(db: db, username: "admin", password: password, now: clock.now())
            var sigs = Set<String>()
            func record(_ res: XCTHTTPResponse) {
                var j = json(res); j["requestId"] = nil
                var h = res.headers; h.remove(name: "X-Request-Id")
                sigs.insert("\(res.status.code)|\(j.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })|\(h.map { "\($0.name.lowercased()):\($0.value)" }.sorted())")
            }
            let a = SyntheticAuthenticator(.es256, rpID: rpID, origin: origin)
            // unknown / malformed / unrelated tokens
            for t in ["", "AAAA", Data(repeating: 1, count: 32).base64URL, "!!!"] {
                var br = browser; try await br.newSession()
                try await br.post("enrollment/options", ["token": t]) { record($0) }
            }
            // expired token
            let expired = try await EnrollmentService(db: db, now: { clock.now().addingTimeInterval(-3 * 86_400) }).issue(account: account, purpose: .recoveryPasskey, lifetime: 3600)
            var b2 = browser; try await b2.newSession()
            try await b2.post("enrollment/options", ["token": expired]) { record($0) }
            // valid token but a faulty registration: wrong origin, wrong challenge, replayed challenge
            for fault in 0..<3 {
                var br = browser; try await br.newSession()
                var ch: (id: String, challenge: Data)?
                try await br.post("enrollment/options", ["token": token]) { ch = creationChallenge($0) }
                let c = try XCTUnwrap(ch)
                var body = registerBody(a, challengeID: c.id, challenge: fault == 1 ? Data(repeating: 5, count: 32) : c.challenge, token: token)
                if fault == 0 {
                    let (cd, att) = a.registration(challenge: c.challenge, origin: "https://evil.test")
                    body["credential"] = ["id": a.credentialID.base64URL, "rawId": a.credentialID.base64URL, "type": "public-key", "response": ["attestationObject": att.base64URL, "clientDataJSON": cd.base64URL]]
                }
                if fault == 2 {
                    // a failed attempt consumes the challenge: the otherwise valid response is refused afterwards
                    var bad = registerBody(a, challengeID: c.id, challenge: Data(repeating: 6, count: 32), token: token)
                    bad["label"] = "x"
                    try await br.post("enrollment/verify", bad) { record($0) }
                }
                try await br.post("enrollment/verify", body) { record($0) }
            }
            XCTAssertEqual(sigs.count, 1, "responses differ: \(sigs)")
            XCTAssertTrue(sigs.first?.hasPrefix("422|") ?? false)
            // the valid token survived all failed attempts (they are retryable until expiry) and no passkey was stored
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM passkeys").first(decoding: C.self)?.c
            XCTAssertEqual(n, 0)
            var ok = browser; try await ok.newSession()
            var ch: (id: String, challenge: Data)?
            try await ok.post("enrollment/options", ["token": token]) { ch = creationChallenge($0) }
            let c = try XCTUnwrap(ch)
            try await ok.post("enrollment/verify", registerBody(a, challengeID: c.id, challenge: c.challenge, token: token)) { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testTwoParallelRegistrationsWithOneTokenYieldOnePasskey() async throws {
        try await withApp { f, browser, clock in
            let (_, token) = try await Bootstrap.createFirstAdmin(db: f.app.db(.mysql), username: "admin", password: password, now: clock.now())
            var prepared: [(Browser, SyntheticAuthenticator, (id: String, challenge: Data))] = []
            for _ in 0..<2 {
                var br = browser; try await br.newSession()
                var ch: (id: String, challenge: Data)?
                try await br.post("enrollment/options", ["token": token]) { ch = creationChallenge($0) }
                prepared.append((br, SyntheticAuthenticator(.es256, rpID: rpID, origin: origin), try XCTUnwrap(ch)))
            }
            let codes = await withTaskGroup(of: UInt.self) { g -> [UInt] in
                for (br, a, c) in prepared {
                    g.addTask {
                        var code: UInt = 0
                        try? await br.post("enrollment/verify", self.registerBody(a, challengeID: c.id, challenge: c.challenge, token: token)) { code = $0.status.code }
                        return code
                    }
                }
                var out: [UInt] = []; for await s in g { out.append(s) }; return out.sorted()
            }
            XCTAssertEqual(codes, [200, 422])
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM passkeys").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)
        }
    }

    func testAddingAPasskeyNeedsAFreshAuthenticatedSessionAndCannotDuplicate() async throws {
        try await withApp { f, browser, clock in
            let db = f.app.db(.mysql)
            let (_, token) = try await Bootstrap.createFirstAdmin(db: db, username: "admin", password: password, now: clock.now())
            let first = SyntheticAuthenticator(.es256, rpID: rpID, origin: origin)
            var br = browser; try await br.newSession()
            var ch: (id: String, challenge: Data)?
            try await br.post("enrollment/options", ["token": token]) { ch = creationChallenge($0) }
            try await br.post("enrollment/verify", registerBody(first, challengeID: try XCTUnwrap(ch).id, challenge: try XCTUnwrap(ch).challenge, token: token)) { XCTAssertEqual($0.status, .ok) }

            // anonymous sessions cannot use the authenticated door
            var anon = browser; try await anon.newSession()
            try await anon.post("passkeys/options", [:]) { XCTAssertEqual($0.status, .unauthorized) }

            let authed = try await login(first, f, as: browser)
            // second device via the session door
            let second = SyntheticAuthenticator(.eddsa, rpID: rpID, origin: origin)
            var sh: (id: String, challenge: Data)?
            try await authed.post("passkeys/options", [:]) { res async throws in
                XCTAssertEqual(res.status, .ok); sh = creationChallenge(res)
                let ex = ((json(res)["publicKey"] as? [String: Any])?["excludeCredentials"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
                XCTAssertEqual(ex, [first.credentialID.base64URL], "existing credentials are excluded")
            }
            try await authed.post("passkeys/verify", registerBody(second, challengeID: try XCTUnwrap(sh).id, challenge: try XCTUnwrap(sh).challenge, token: nil, label: "Zweites Gerät")) { XCTAssertEqual($0.status, .ok) }
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM passkeys").first(decoding: C.self)?.c
            XCTAssertEqual(n, 2)
            // registering the same credential id again is refused uniformly
            var dh: (id: String, challenge: Data)?
            try await authed.post("passkeys/options", [:]) { dh = creationChallenge($0) }
            try await authed.post("passkeys/verify", registerBody(second, challengeID: try XCTUnwrap(dh).id, challenge: try XCTUnwrap(dh).challenge, token: nil)) { XCTAssertEqual($0.status.code, 422) }
            // the new key logs in too
            _ = try await login(second, f, as: browser)
            // after 5 minutes the session is no longer "fresh": re-authentication is required
            clock.t = clock.t.addingTimeInterval(301)
            // (the session itself is still valid within 30 min idle, so the answer is reauthentication, not 401)
            try await authed.post("passkeys/options", [:]) { res async throws in
                XCTAssertEqual(res.status, .forbidden); XCTAssertEqual(json(res)["code"] as? String, "reauthentication_required")
            }
        }
    }

    func testBootstrapRulesAndRecoveryLink() async throws {
        try await DBFixture.with { f in
            let db = f.app.db(.mysql)
            for bad in ["", "Ab", "UPPER", "a b", "-x", String(repeating: "a", count: 121)] {
                do { _ = try await Bootstrap.createFirstAdmin(db: db, username: bad, password: "long enough pw"); XCTFail(bad) } catch let e as Bootstrap.Failure { XCTAssertEqual(e, .usernameInvalid) }
            }
            do { _ = try await Bootstrap.createFirstAdmin(db: db, username: "admin", password: "short"); XCTFail() } catch let e as Bootstrap.Failure { XCTAssertEqual(e, .passwordTooShort) }
            let none = try await f.sql.raw("SELECT COUNT(*) AS c FROM accounts").first(decoding: C.self)?.c
            XCTAssertEqual(none, 0)
            _ = try await Bootstrap.createFirstAdmin(db: db, username: "admin", password: "long enough pw")
            do { _ = try await Bootstrap.createFirstAdmin(db: db, username: "second", password: "long enough pw"); XCTFail("second bootstrap must refuse") } catch let e as Bootstrap.Failure { XCTAssertEqual(e, .accountsExist) }
            let one = try await f.sql.raw("SELECT COUNT(*) AS c FROM accounts").first(decoding: C.self)?.c
            XCTAssertEqual(one, 1)
            // the stored hash is Argon2id and verifies
            struct H: Decodable { let password_hash: String }
            let h = try await f.sql.raw("SELECT password_hash FROM accounts").first(decoding: H.self)?.password_hash ?? ""
            XCTAssertTrue(h.hasPrefix("$argon2id$")); XCTAssertTrue(Argon2id.verify("long enough pw", encoded: h))
            // recovery link: unknown / inactive accounts get none
            _ = try await Bootstrap.issueEnrollment(db: db, username: "admin")
            do { _ = try await Bootstrap.issueEnrollment(db: db, username: "nobody"); XCTFail() } catch let e as Bootstrap.Failure { XCTAssertEqual(e, .unknownAccount) }
            try await f.sql.raw("UPDATE accounts SET active = 0").run()
            do { _ = try await Bootstrap.issueEnrollment(db: db, username: "admin"); XCTFail() } catch let e as Bootstrap.Failure { XCTAssertEqual(e, .unknownAccount) }
        }
    }

    func testParallelBootstrapCreatesExactlyOneAccount() async throws {
        try await DBFixture.with { f in
            let db = f.app.db(.mysql)
            let results = await withTaskGroup(of: Bool.self) { g -> [Bool] in
                for i in 0..<4 { g.addTask { (try? await Bootstrap.createFirstAdmin(db: db, username: "admin\(i)", password: "long enough pw")) != nil } }
                var out: [Bool] = []; for await r in g { out.append(r) }; return out
            }
            XCTAssertEqual(results.filter { $0 }.count, 1)
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM accounts").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)
        }
    }
}
