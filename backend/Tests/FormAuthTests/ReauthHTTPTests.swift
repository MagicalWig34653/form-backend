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

/// Passkey step-up (POST /auth/reauth/options|verify): renews `authenticated_at` of the calling authenticated session only,
/// with a UV passkey of the same account, one-time session-bound challenge, counter rule, CSRF and throttles. Real DB.
final class ReauthHTTPTests: XCTestCase {
    private let origin = "https://admin.example.test", rpID = "admin.example.test"
    private let key = try! StaticServerKey(Data(repeating: 9, count: 32))
    private let password = "correct horse battery"
    private struct C: Decodable { let c: Int }
    private struct At: Decodable { let authenticated_at: Date? }

    private final class Clock: @unchecked Sendable { var t = Date(); func now() -> Date { t } }

    private struct Browser {
        let app: Application; let origin: String
        var cookie: String? = nil, csrf: String? = nil
        func headers(csrf useCSRF: Bool = true, origin o: String? = nil) -> HTTPHeaders {
            var h = HTTPHeaders()
            if let cookie { h.add(name: .cookie, value: cookie) }
            if useCSRF, let csrf { h.add(name: "X-CSRF-Token", value: csrf) }
            h.add(name: "Origin", value: o ?? origin); h.add(name: "X-Test-IP", value: "203.0.113.9"); h.contentType = .json
            return h
        }
        mutating func newSession() async throws {
            var c = self
            var h = headers(); h.remove(name: .cookie); h.remove(name: "X-CSRF-Token")
            try await app.test(.GET, "admin/api/v1/auth/session", headers: h) { res async throws in
                c.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }
                c.csrf = (try? JSONSerialization.jsonObject(with: Data(buffer: res.body)) as? [String: Any])?["csrfToken"] as? String
            }
            self = c
        }
        func post(_ path: String, _ body: [String: Any], csrf: Bool = true, origin o: String? = nil, _ check: (XCTHTTPResponse) async throws -> Void) async throws {
            let data = try JSONSerialization.data(withJSONObject: body)
            try await app.test(.POST, "admin/api/v1/auth/\(path)", headers: headers(csrf: csrf, origin: o), body: ByteBuffer(data: data), afterResponse: check)
        }
    }

    private struct Env {
        let f: DBFixture; let clock: Clock; let browser: Browser
        var sql: SQLDatabase { f.sql }
    }

    private func json(_ r: XCTHTTPResponse) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(buffer: r.body)) as? [String: Any]) ?? [:] }

    private func withApp(secondFactor: Bool = false, _ body: (Env) async throws -> Void) async throws {
        try await DBFixture.with { f in
            try HTTPSetup.configure(f.app)
            let clock = Clock()
            // These tests simulate "stale but still signed in" by advancing the clock by 301 s, so they pin the window to 5 minutes
            // (the default is 30 min, and an authenticated session already idles out after 30 min).
            try await SystemSettings.write(f.app.db(.mysql) as! SQLDatabase, key: "auth.freshLoginMinutes", value: "5", at: DB.time(Date()))
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: rpID, origin: origin), clientIP: { $0.headers.first(name: "X-Test-IP") ?? "unknown" })
            cfg.secondFactorRequired = secondFactor
            cfg.requestBudget = (100_000, 60); cfg.loginBudget = (100_000, 60)
            FormAuth.register(f.app, config: cfg, keys: key, now: { clock.now() })
            try await body(Env(f: f, clock: clock, browser: Browser(app: f.app, origin: origin)))
        }
    }

    private func challenge(_ res: XCTHTTPResponse) -> (id: String, challenge: Data)? {
        guard let pk = json(res)["publicKey"] as? [String: Any], let id = json(res)["challengeId"] as? String, let c = pk["challenge"] as? String, let d = Data(base64URLEncoded: c) else { return nil }
        return (id, d)
    }

    /// Registers a synthetic ES256 passkey for `account` through a one-time enrollment link.
    private func enroll(_ e: Env, account: UUID, token: String? = nil) async throws -> SyntheticAuthenticator {
        let a = SyntheticAuthenticator(.es256, rpID: rpID, origin: origin)
        let t: String
        if let token { t = token } else { t = try await EnrollmentService(db: e.f.app.db(.mysql), now: { e.clock.now() }).issue(account: account, purpose: .recoveryPasskey, lifetime: 3600) }
        var br = e.browser; try await br.newSession()
        var ch: (id: String, challenge: Data)?
        try await br.post("enrollment/options", ["token": t]) { ch = challenge($0) }
        let c = try XCTUnwrap(ch)
        let (cd, att) = a.registration(challenge: c.challenge)
        try await br.post("enrollment/verify", ["token": t, "challengeId": c.id, "label": "Gerät", "credential": ["id": a.credentialID.base64URL, "rawId": a.credentialID.base64URL, "type": "public-key",
            "response": ["attestationObject": att.base64URL, "clientDataJSON": cd.base64URL]]]) { XCTAssertEqual($0.status, .ok) }
        return a
    }

    private func assertionBody(_ a: SyntheticAuthenticator, challengeID: String, challenge: Data, account: UUID) -> [String: Any] {
        let asr = a.assertion(challenge: challenge)
        return ["challengeId": challengeID, "credential": ["id": a.credentialID.base64URL, "rawId": a.credentialID.base64URL, "type": "public-key",
            "response": ["authenticatorData": asr.authenticatorData.base64URL, "clientDataJSON": asr.clientDataJSON.base64URL, "signature": asr.signature.base64URL,
                         "userHandle": Data(account.uuidString.lowercased().utf8).base64URL]]]
    }

    /// Full login: passkey alone (internal) or passkey + password (second factor policy).
    private func login(_ e: Env, _ a: SyntheticAuthenticator, account: UUID, secondFactor: Bool = false) async throws -> Browser {
        var br = e.browser
        try await br.newSession()
        var ch: (id: String, challenge: Data)?
        try await br.post("passkey/options", [:]) { ch = challenge($0) }
        let c = try XCTUnwrap(ch)
        var next = br
        try await br.post("passkey/verify", assertionBody(a, challengeID: c.id, challenge: c.challenge, account: account)) { res async throws in
            XCTAssertEqual(res.status, .ok, String(decoding: Data(buffer: res.body), as: UTF8.self))
            XCTAssertEqual(json(res)["state"] as? String, secondFactor ? "factor_pending" : "authenticated")
            next.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }; next.csrf = json(res)["csrfToken"] as? String
        }
        if secondFactor {
            try await next.post("second-factor/password", ["method": "password", "password": password]) { res async throws in
                XCTAssertEqual(json(res)["state"] as? String, "authenticated")
                next.cookie = res.headers[.setCookie].first.flatMap { $0.split(separator: ";").first.map(String.init) }; next.csrf = json(res)["csrfToken"] as? String
            }
        }
        return next
    }

    /// Forgets the per-account step-up failure history so a test can probe several refusal causes in a row (throttling is tested separately).
    private func resetAccountThrottle(_ e: Env) async throws {
        try await e.sql.raw("DELETE FROM auth_throttles WHERE scope = 'account'").run()
    }

    private func sessionAt(_ e: Env, _ br: Browser) async throws -> Date? {
        let token = String(try XCTUnwrap(br.cookie).split(separator: "=", maxSplits: 1)[1])
        let s = try await SessionService(db: e.f.app.db(.mysql), keys: key, now: { e.clock.now() }).resolve(token: token)
        let id = try XCTUnwrap(s).id
        return try await e.sql.raw("SELECT authenticated_at FROM sessions WHERE id = \(bind: DB.bin(id))").first(decoding: At.self)?.authenticated_at
    }

    private func options(_ br: Browser) async throws -> (id: String, challenge: Data) {
        var ch: (id: String, challenge: Data)?
        try await br.post("reauth/options", [:]) { res async throws in
            XCTAssertEqual(res.status, .ok, String(decoding: Data(buffer: res.body), as: UTF8.self)); ch = challenge(res)
        }
        return try XCTUnwrap(ch)
    }

    private func expectFailed(_ res: XCTHTTPResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(res.status, .unauthorized, file: file, line: line)
        XCTAssertEqual(json(res)["code"] as? String, "authentication_failed", file: file, line: line)
    }

    private func setup(_ e: Env) async throws -> (account: UUID, a: SyntheticAuthenticator) {
        let (account, token) = try await Bootstrap.createFirstAdmin(db: e.f.app.db(.mysql), username: "admin", password: password, now: e.clock.now())
        let a = try await enroll(e, account: account, token: token)
        return (account, a)
    }

    // MARK: tests

    func testStepUpRenewsFreshnessOfThisSessionOnlyWithoutNewToken() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            let br = try await login(e, a, account: account)
            let other = try await login(e, a, account: account)
            let otherBefore = try await sessionAt(e, other)
            e.clock.t = e.clock.t.addingTimeInterval(301)
            // stale: the sensitive action is refused
            try await br.post("passkeys/options", [:]) { XCTAssertEqual(json($0)["code"] as? String, "reauthentication_required") }
            var opts: (id: String, challenge: Data)?
            try await br.post("reauth/options", [:]) { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-store")
                let pk = json(res)["publicKey"] as? [String: Any] ?? [:]
                XCTAssertEqual(pk["userVerification"] as? String, "required")
                XCTAssertEqual(pk["rpId"] as? String, rpID)
                XCTAssertEqual((pk["allowCredentials"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [a.credentialID.base64URL])
                opts = challenge(res)
            }
            let o = try XCTUnwrap(opts)
            struct Ch: Decodable { let purpose: String; let account_id: Blob?; let challenge_hash: Blob? }
            let stored = try await e.sql.raw("SELECT purpose, account_id, challenge_hash FROM auth_challenges WHERE id = \(bind: DB.bin(UUID(uuidString: o.id)!))").first(decoding: Ch.self)
            XCTAssertEqual(stored?.purpose, "fresh-auth")
            XCTAssertEqual(stored?.account_id.flatMap { DB.uuid($0.data) }, account)
            XCTAssertEqual(stored?.challenge_hash?.data, Data(SHA256.hash(data: o.challenge)), "only the hash is stored")
            try await br.post("reauth/verify", assertionBody(a, challengeID: o.id, challenge: o.challenge, account: account)) { res async throws in
                XCTAssertEqual(res.status, .ok, String(decoding: Data(buffer: res.body), as: UTF8.self))
                XCTAssertEqual(json(res)["status"] as? String, "fresh")
                XCTAssertNotNil(json(res)["freshUntil"] as? String)
                XCTAssertTrue(res.headers[.setCookie].isEmpty, "no new session token")
            }
            let renewed = try await sessionAt(e, br)
            let at = try XCTUnwrap(renewed)
            XCTAssertEqual(at.timeIntervalSince1970, e.clock.t.timeIntervalSince1970, accuracy: 0.01)
            // only this session was renewed
            let otherAfter = try await sessionAt(e, other)
            XCTAssertEqual(otherAfter, otherBefore)
            // the same cookie and CSRF token keep working and the sensitive action now passes
            try await br.post("passkeys/options", [:]) { XCTAssertEqual($0.status, .ok) }
            // state, method and rights version untouched
            struct S: Decodable { let state: String; let auth_method: String?; let rights_version: UInt64? }
            let rows = try await e.sql.raw("SELECT state, auth_method, rights_version FROM sessions WHERE state = 'authenticated'").all(decoding: S.self)
            XCTAssertEqual(rows.count, 2)
            XCTAssertTrue(rows.allSatisfy { $0.auth_method == "passkey" })
            // counter advanced and one audit event without secrets
            struct P: Decodable { let sign_count: Int }
            let count = try await e.sql.raw("SELECT sign_count FROM passkeys").first(decoding: P.self)?.sign_count
            XCTAssertEqual(count, Int(a.signCount))
            struct A: Decodable { let details: String; let actor_kind: String }
            let audit = try await e.sql.raw("SELECT safe_details_json AS details, actor_kind FROM audit_events WHERE action_code = 'auth.reauth'").all(decoding: A.self)
            XCTAssertEqual(audit.count, 1)
            XCTAssertEqual(audit.first?.actor_kind, "human")
            XCTAssertFalse(audit.first?.details.contains(o.challenge.base64URL) ?? true)
            // replay of the exact same, valid assertion is refused (challenge consumed)
            let before = try await sessionAt(e, br)
            e.clock.t = e.clock.t.addingTimeInterval(10)
            let replay = assertionBody(a, challengeID: o.id, challenge: o.challenge, account: account)
            try await br.post("reauth/verify", replay) { expectFailed($0) }
            let after = try await sessionAt(e, br)
            XCTAssertEqual(after, before)
        }
    }

    func testPasskeyOfAnotherAccountIsRefusedNeutrally() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            let otherAccount = try await e.f.account()
            let b = try await enroll(e, account: otherAccount)
            let br = try await login(e, a, account: account)
            e.clock.t = e.clock.t.addingTimeInterval(301)
            let before = try await sessionAt(e, br)
            // B signs A's challenge correctly with its own key and user handle: still refused, same answer as any failure
            let o = try await options(br)
            try await br.post("reauth/verify", assertionBody(b, challengeID: o.id, challenge: o.challenge, account: otherAccount)) { expectFailed($0) }
            // ... and also with A's user handle
            let o2 = try await options(br)
            try await br.post("reauth/verify", assertionBody(b, challengeID: o2.id, challenge: o2.challenge, account: account)) { expectFailed($0) }
            let after = try await sessionAt(e, br)
            XCTAssertEqual(after, before)
            struct P: Decodable { let sign_count: Int }
            let bCount = try await e.sql.raw("SELECT sign_count FROM passkeys WHERE account_id = \(bind: DB.bin(otherAccount))").first(decoding: P.self)?.sign_count
            XCTAssertEqual(bCount, 0, "a foreign key's counter is never advanced")
            try await br.post("passkeys/options", [:]) { XCTAssertEqual(json($0)["code"] as? String, "reauthentication_required") }
        }
    }

    func testExpiredConsumedAndForeignChallengesAreRefused() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            let br = try await login(e, a, account: account)
            let second = try await login(e, a, account: account)
            e.clock.t = e.clock.t.addingTimeInterval(301)
            let before = try await sessionAt(e, br)
            // expired (challenge lifetime 120 s)
            let o1 = try await options(br)
            e.clock.t = e.clock.t.addingTimeInterval(121)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o1.id, challenge: o1.challenge, account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            // consumed by a failed attempt (wrong challenge signed), then the valid response is refused too
            let o2 = try await options(br)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o2.id, challenge: Data(repeating: 4, count: 32), account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o2.id, challenge: o2.challenge, account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            // a challenge issued to another session of the same account cannot be used here
            let foreign = try await options(second)
            try await br.post("reauth/verify", assertionBody(a, challengeID: foreign.id, challenge: foreign.challenge, account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            // a newer options call revokes the older open challenge
            let old = try await options(br)
            _ = try await options(br)
            try await br.post("reauth/verify", assertionBody(a, challengeID: old.id, challenge: old.challenge, account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            let after = try await sessionAt(e, br)
            XCTAssertEqual(after, before)
            // a login challenge (purpose passkey-login) is not a step-up challenge
            var anon = e.browser; try await anon.newSession()
            var login: (id: String, challenge: Data)?
            try await anon.post("passkey/options", [:]) { login = challenge($0) }
            let l = try XCTUnwrap(login)
            try await br.post("reauth/verify", assertionBody(a, challengeID: l.id, challenge: l.challenge, account: account)) { expectFailed($0) }
            try await resetAccountThrottle(e)
            let n = try await e.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'auth.reauth'").first(decoding: C.self)?.c
            XCTAssertEqual(n, 0)
        }
    }

    func testAnonymousAndFactorPendingSessionsAndMissingCSRFAreRefused() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            var anon = e.browser; try await anon.newSession()
            try await anon.post("reauth/options", [:]) { XCTAssertEqual($0.status, .unauthorized) }
            try await anon.post("reauth/verify", assertionBody(a, challengeID: UUID().uuidString, challenge: Data(repeating: 1, count: 32), account: account)) { XCTAssertEqual($0.status, .unauthorized) }
            // factor_pending (passkey done, password missing) cannot step up
            let sessions = SessionService(db: e.f.app.db(.mysql), keys: key, now: { e.clock.now() })
            let (_, anonRecord) = try await sessions.createAnonymous()
            let (pendingToken, _) = try await sessions.rotate(from: anonRecord, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 0)
            var pending = e.browser
            pending.cookie = "\(SessionService.cookieName)=\(pendingToken)"
            try await e.f.app.test(.GET, "admin/api/v1/auth/session", headers: pending.headers()) { res async throws in
                XCTAssertEqual(json(res)["state"] as? String, "factor_pending"); pending.csrf = json(res)["csrfToken"] as? String
            }
            try await pending.post("reauth/options", [:]) { XCTAssertEqual($0.status, .unauthorized) }
            try await pending.post("reauth/verify", assertionBody(a, challengeID: UUID().uuidString, challenge: Data(repeating: 1, count: 32), account: account)) { XCTAssertEqual($0.status, .unauthorized) }
            // authenticated, but without CSRF token or with a foreign Origin
            let br = try await login(e, a, account: account)
            try await br.post("reauth/options", [:], csrf: false) { XCTAssertEqual($0.status, .forbidden); XCTAssertEqual(json($0)["code"] as? String, "csrf_invalid") }
            try await br.post("reauth/options", [:], origin: "https://evil.test") { XCTAssertEqual($0.status, .forbidden) }
            let o = try await options(br)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o.id, challenge: o.challenge, account: account), csrf: false) {
                XCTAssertEqual($0.status, .forbidden); XCTAssertEqual(json($0)["code"] as? String, "csrf_invalid")
            }
            let n = try await e.sql.raw("SELECT COUNT(*) AS c FROM audit_events WHERE action_code = 'auth.reauth'").first(decoding: C.self)?.c
            XCTAssertEqual(n, 0)
        }
    }

    func testCounterRegressionIsRefused() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            let br = try await login(e, a, account: account)
            e.clock.t = e.clock.t.addingTimeInterval(301)
            let before = try await sessionAt(e, br)
            // a cloned authenticator lags behind the stored counter
            try await e.sql.raw("UPDATE passkeys SET sign_count = 1000").run()
            let o = try await options(br)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o.id, challenge: o.challenge, account: account)) { expectFailed($0) }
            let after = try await sessionAt(e, br)
            XCTAssertEqual(after, before)
            struct P: Decodable { let sign_count: Int }
            let count = try await e.sql.raw("SELECT sign_count FROM passkeys").first(decoding: P.self)?.sign_count
            XCTAssertEqual(count, 1000)
        }
    }

    func testFailuresAreThrottled() async throws {
        try await withApp { e in
            let (account, a) = try await setup(e)
            let br = try await login(e, a, account: account)
            for _ in 0..<5 {
                let o = try await options(br)
                try await br.post("reauth/verify", assertionBody(a, challengeID: o.id, challenge: Data(repeating: 3, count: 32), account: account)) { res async throws in
                    XCTAssertTrue([401, 429].contains(res.status.code))
                }
            }
            // locked: even a valid assertion is not checked now
            let o = try await options(br)
            try await br.post("reauth/verify", assertionBody(a, challengeID: o.id, challenge: o.challenge, account: account)) { res async throws in
                XCTAssertEqual(res.status, .tooManyRequests); XCTAssertNotNil(res.headers.first(name: "Retry-After"))
            }
        }
    }

    func testSecondFactorPolicyRefusesStepUp() async throws {
        try await withApp(secondFactor: true) { e in
            let (account, a) = try await setup(e)
            let br = try await login(e, a, account: account, secondFactor: true)
            e.clock.t = e.clock.t.addingTimeInterval(301)
            let before = try await sessionAt(e, br)
            try await br.post("reauth/options", [:]) { res async throws in
                XCTAssertEqual(res.status, .conflict); XCTAssertEqual(json(res)["code"] as? String, "second_factor_required")
            }
            try await br.post("reauth/verify", assertionBody(a, challengeID: UUID().uuidString, challenge: Data(repeating: 1, count: 32), account: account)) { res async throws in
                XCTAssertEqual(res.status, .conflict); XCTAssertEqual(json(res)["code"] as? String, "second_factor_required")
            }
            let after = try await sessionAt(e, br)
            XCTAssertEqual(after, before)
            let n = try await e.sql.raw("SELECT COUNT(*) AS c FROM auth_challenges WHERE purpose = 'fresh-auth'").first(decoding: C.self)?.c
            XCTAssertEqual(n, 0)
        }
    }
}
