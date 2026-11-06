// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
@testable import FormAuth

/// Login flow against a real DB with the synthetic PoC vectors (valid signatures for a fixed challenge).
final class LoginDBTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_793_012_400); func now() -> Date { t } }
    private struct C: Decodable { let c: Int }
    private struct FakePasswords: PasswordVerifier {
        let expected: String
        func verify(password: String, hash: String?) async -> Bool { hash != nil && password == expected }
    }

    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private let ip = "203.0.113.9"

    private struct Env {
        let f: DBFixture; let clock: Clock; let login: LoginService; let sessions: SessionService
        let vectors: VectorFile; let account: UUID
    }

    private func b(_ s: String) -> Data { Data(base64URLEncoded: s)! }

    private func loadVectors() throws -> VectorFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }

    private func withEnv(vector name: String, passwordHash: String = "stored-hash", secondFactor: Bool = true, _ body: (Env, VectorFile.Vector) async throws -> Void) async throws {
        let vectors = try loadVectors()
        let v = try XCTUnwrap(vectors.vectors.first { $0.name == name })
        try await DBFixture.with { f in
            let clock = Clock()
            let account = UUID(uuidString: vectors.userHandleText)!
            try await f.sql.raw("""
                INSERT INTO accounts (id, username, password_hash, active, mcp_allowed, rights_version, created_at)
                VALUES (\(bind: DB.bin(account)), 'vector-user', \(bind: passwordHash), 1, 0, 4, '2026-10-30 12:00:00.000000')
                """).run()
            let k = vectors.keys[v.key]!
            try await f.sql.raw("""
                INSERT INTO passkeys (credential_id, account_id, user_handle, public_key_bytes, public_key_encoding, cose_algorithm, sign_count, label, rp_id, created_at)
                VALUES (\(bind: Blob(b(k.credentialId))), \(bind: DB.bin(account)), \(bind: Blob(Data(vectors.userHandleText.utf8))), \(bind: Blob(Data(k.publicKeyPem.utf8))),
                  'pem-spki', \(bind: k.alg), \(bind: Int(v.storedSignCount)), 'vector', \(bind: vectors.rpId), '2026-10-30 12:00:00.000000')
                """).run()
            let db = f.app.db(.mysql)
            let sessions = SessionService(db: db, keys: key, now: { clock.now() })
            let throttles = ThrottleService(db: db, keys: key, now: { clock.now() })
            let login = LoginService(db: db, sessions: sessions, throttles: throttles, passwords: FakePasswords(expected: "correct horse"),
                                     relyingParty: RelyingParty(rpID: vectors.rpId, origin: vectors.origin), secondFactorRequired: secondFactor, now: { clock.now() })
            try await body(Env(f: f, clock: clock, login: login, sessions: sessions, vectors: vectors, account: account), v)
        }
    }

    private func input(_ e: Env, _ v: VectorFile.Vector) -> AssertionInput {
        AssertionInput(credentialID: b(e.vectors.keys[v.key]!.credentialId), clientDataJSON: b(v.clientDataJSON), authenticatorData: b(v.authenticatorData),
                       signature: b(v.signature), userHandle: b(v.userHandle))
    }

    /// Installs a challenge row whose hash matches the vector's challenge (the vector was signed over it).
    private func installChallenge(_ e: Env, _ v: VectorFile.Vector, session: SessionRecord, createdAgo: TimeInterval = 0) async throws {
        let created = e.clock.t.addingTimeInterval(-createdAgo)
        try await e.f.sql.raw("""
            INSERT INTO auth_challenges (id, session_id, purpose, challenge_hash, factor_method, created_at, expires_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(session.id)), 'passkey-login', \(bind: Blob(Data(SHA256.hash(data: b(v.challenge))))), 'passkey',
              \(bind: DB.time(created)), \(bind: DB.time(created.addingTimeInterval(120))))
            """).run()
    }

    private func expectFailed<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        do { _ = try await body(); XCTFail("expected authentication_failed", file: file, line: line); return false }
        catch let e as AuthenticationFailed { return e.code == "authentication_failed" }
        catch { XCTFail("unexpected \(error)", file: file, line: line); return false }
    }

    private func counter(_ e: Env) async throws -> Int {
        struct R: Decodable { let sign_count: Int }
        return try await e.f.sql.raw("SELECT sign_count FROM passkeys").first(decoding: R.self)!.sign_count
    }

    func testInternalPasskeyAloneAndFreshLoginExpiry() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0", passwordHash: "", secondFactor: false) { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let (token, auth) = try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip)
            XCTAssertEqual(auth.state, .authenticated)
            XCTAssertEqual(auth.authMethod, "passkey")
            let publicSessions = SessionService(db: e.f.app.db(.mysql), keys: key, audience: "public", now: { e.clock.now() })
            let crossed = try await publicSessions.resolve(token: token)
            XCTAssertNil(crossed)
            let request = Request(application: e.f.app, method: .GET, url: "/admin/api/v1/me",
                headers: ["Cookie": "\(SessionService.cookieName)=\(token)", "Host": "admin.example.test", "X-Forwarded-Host": "internal.example.test"],
                on: e.f.app.eventLoopGroup.next())
            var publicConfig = AuthConfig(relyingParty: RelyingParty(rpID: e.vectors.rpId, origin: e.vectors.origin))
            publicConfig.listener = "public"
            let publicGuard = AuthGuard(sessions: publicSessions, throttles: ThrottleService(db: e.f.app.db(.mysql), keys: key), config: publicConfig)
            do { _ = try await publicGuard.requireAuthenticated(request, mutation: false); XCTFail("cross-listener cookie") }
            catch let error as Abort { XCTAssertEqual(error.status, .unauthorized) }
            var strictInternal = publicConfig
            strictInternal.listener = "internal"
            strictInternal.secondFactorRequired = true
            let strictGuard = AuthGuard(sessions: e.sessions, throttles: publicGuard.throttles, config: strictInternal)
            do { _ = try await strictGuard.requireAuthenticated(request, mutation: false); XCTFail("policy changed") }
            catch let error as Abort { XCTAssertEqual(error.status, .unauthorized) }
            let publicAnon = try await publicSessions.resolve(token: (try await e.sessions.createAnonymous()).token)
            XCTAssertNil(publicAnon)
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: e.vectors.rpId, origin: e.vectors.origin))
            cfg.secondFactorRequired = false
            let guarder = AuthGuard(sessions: e.sessions, throttles: ThrottleService(db: e.f.app.db(.mysql), keys: key), config: cfg)
            try await guarder.requireFreshAuthentication(auth, now: e.clock.t)
            e.clock.t.addTimeInterval(301)
            do { try await guarder.requireFreshAuthentication(auth, now: e.clock.t); XCTFail("stale") }
            catch is ReauthenticationRequired {}
            // Fresh confirmation is another UV passkey assertion and rotates the old session.
            let (_, freshAnon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: freshAnon)
            let (_, fresh) = try await e.login.finishPasskey(session: freshAnon, input: input(e, v), clientIP: ip)
            try await guarder.requireFreshAuthentication(fresh, now: e.clock.t)
        }
    }

    func testPublicAndInternalOptInRequirePasswordAndMissingPasswordFails() async throws {
        for audience in ["public", "internal"] {
            try await withEnv(vector: "es256_ok_counter_0_0", passwordHash: "") { e, v in
                let sessions = SessionService(db: e.f.app.db(.mysql), keys: key, audience: audience, now: { e.clock.now() })
                let login = LoginService(db: e.f.app.db(.mysql), sessions: sessions,
                    throttles: ThrottleService(db: e.f.app.db(.mysql), keys: key, now: { e.clock.now() }),
                    passwords: FakePasswords(expected: "correct horse"),
                    relyingParty: RelyingParty(rpID: e.vectors.rpId, origin: e.vectors.origin), secondFactorRequired: true, now: { e.clock.now() })
                let (_, anon) = try await sessions.createAnonymous()
                try await installChallenge(e, v, session: anon)
                let (_, pending) = try await login.finishPasskey(session: anon, input: input(e, v), clientIP: ip)
                XCTAssertEqual(pending.state, .factorPending)
                let failed = await expectFailed { try await login.verifySecondFactorPassword(session: pending, password: "correct horse", clientIP: ip) }
                XCTAssertTrue(failed)
            }
        }
    }

    func testInternalPasskeyWithoutUVIsRejected() async throws {
        try await withEnv(vector: "es256_uv_missing", secondFactor: false) { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let failed = await expectFailed { try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(failed)
        }
    }

    func testFullLoginPasskeyThenPasswordRotatesTwice() async throws {
        try await withEnv(vector: "es256_ok_counter_increase") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            let challenge = try await e.login.beginPasskey(session: anon)
            XCTAssertEqual(challenge.challenge.count, 32)
            // replace the issued challenge hash by the vector's (the vector signature covers its own challenge)
            try await e.f.sql.raw("UPDATE auth_challenges SET challenge_hash = \(bind: Blob(Data(SHA256.hash(data: b(v.challenge)))))").run()
            let (pendingToken, pending) = try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip)
            XCTAssertEqual(pending.state, .factorPending)
            XCTAssertEqual(pending.accountID, e.account)
            let oldGone = try await e.sessions.resolve(token: pendingToken)
            XCTAssertEqual(oldGone?.state, .factorPending)
            let c = try await counter(e)
            XCTAssertGreaterThan(c, 5)  // advanced from the stored 5
            // password: wrong first, then right
            _ = await expectFailed { try await e.login.verifySecondFactorPassword(session: pending, password: "nope", clientIP: ip) }
            let (token, auth) = try await e.login.verifySecondFactorPassword(session: pending, password: "correct horse", clientIP: ip)
            XCTAssertEqual(auth.state, .authenticated)
            XCTAssertEqual(auth.authMethod, "passkey+password")
            XCTAssertEqual(auth.rightsVersion, 4)
            let resolved = try await e.sessions.resolve(token: token)
            XCTAssertEqual(resolved?.state, .authenticated)
            let stale = try await e.sessions.resolve(token: pendingToken)
            XCTAssertNil(stale)   // factor_pending session was replaced
        }
    }

    func testChallengeIsConsumedEvenWhenVerificationFailsAndCannotBeReplayed() async throws {
        try await withEnv(vector: "es256_bad_signature") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let failed = await expectFailed { try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(failed)
            let consumed = try await e.f.sql.raw("SELECT COUNT(*) AS c FROM auth_challenges WHERE consumed_at IS NOT NULL").first(decoding: C.self)?.c
            XCTAssertEqual(consumed, 1)
            // the same (even correct) assertion again: no open challenge left
            let again = await expectFailed { try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(again)
            let c = try await counter(e); XCTAssertEqual(c, 0)
        }
    }

    func testReplayOfAValidAssertionFailsAndCounterAdvancedOnce() async throws {
        try await withEnv(vector: "es256_ok_counter_increase") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            _ = try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip)
            let (_, anon2) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon2)
            let replay = await expectFailed { try await e.login.finishPasskey(session: anon2, input: input(e, v), clientIP: ip) }  // counter not > stored
            XCTAssertTrue(replay)
        }
    }

    func testExpiredChallengeIsRejectedAndConsumed() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon, createdAgo: 121)
            let failed = await expectFailed { try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(failed)
            let consumed = try await e.f.sql.raw("SELECT COUNT(*) AS c FROM auth_challenges WHERE consumed_at IS NOT NULL").first(decoding: C.self)?.c
            XCTAssertEqual(consumed, 1)
        }
    }

    func testUnknownCredentialAndWrongSessionAreUniformFailures() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            var bad = input(e, v)
            bad = AssertionInput(credentialID: Data([9, 9, 9]), clientDataJSON: bad.clientDataJSON, authenticatorData: bad.authenticatorData, signature: bad.signature, userHandle: bad.userHandle)
            let unknown = await expectFailed { try await e.login.finishPasskey(session: anon, input: bad, clientIP: ip) }
            XCTAssertTrue(unknown)
            // a challenge issued for another session is not usable
            let (_, other) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let wrong = await expectFailed { try await e.login.finishPasskey(session: other, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(wrong)
        }
    }

    func testInactiveAccountCannotLogIn() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, v in
            try await e.f.sql.raw("UPDATE accounts SET active = 0").run()
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let failed = await expectFailed { try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip) }
            XCTAssertTrue(failed)
        }
    }

    func testSecondFactorLockoutAfterFiveFailuresIs429AndDoesNotRevealPassword() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, v in
            let (_, anon) = try await e.sessions.createAnonymous()
            try await installChallenge(e, v, session: anon)
            let (_, pending) = try await e.login.finishPasskey(session: anon, input: input(e, v), clientIP: ip)
            for _ in 1...5 {
                e.clock.t.addTimeInterval(61) // outrun the backoff, reach the limit
                _ = await expectFailed { try await e.login.verifySecondFactorPassword(session: pending, password: "x", clientIP: ip) }
            }
            do { _ = try await e.login.verifySecondFactorPassword(session: pending, password: "correct horse", clientIP: ip); XCTFail("locked") }
            catch let r as RateLimited { XCTAssertGreaterThanOrEqual(r.retryAfter, 1) }
        }
    }

    func testSecondFactorNeedsFactorPendingSession() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, _ in
            let (_, anon) = try await e.sessions.createAnonymous()
            let failed = await expectFailed { try await e.login.verifySecondFactorPassword(session: anon, password: "correct horse", clientIP: ip) }
            XCTAssertTrue(failed)
        }
    }

    func testBeginRevokesEarlierOpenChallenges() async throws {
        try await withEnv(vector: "es256_ok_counter_0_0") { e, _ in
            let (_, anon) = try await e.sessions.createAnonymous()
            _ = try await e.login.beginPasskey(session: anon)
            _ = try await e.login.beginPasskey(session: anon)
            let open = try await e.f.sql.raw("SELECT COUNT(*) AS c FROM auth_challenges WHERE revoked_at IS NULL AND consumed_at IS NULL").first(decoding: C.self)?.c
            XCTAssertEqual(open, 1)
        }
    }
}
