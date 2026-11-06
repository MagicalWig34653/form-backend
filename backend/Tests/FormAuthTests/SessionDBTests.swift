// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAuth

final class SessionDBTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_793_012_400); func now() -> Date { t } }

    private func service(_ f: DBFixture, _ clock: Clock, key: StaticServerKey? = nil) -> SessionService {
        SessionService(db: f.app.db(.mysql), keys: key ?? self.key, now: { clock.now() })
    }

    func testAnonymousCreateResolveAndExpiryWithoutExtension() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = service(f, clock)
            let (token, created) = try await s.createAnonymous()
            XCTAssertEqual(created.state, .anonymous)
            let r1 = try await s.resolve(token: token)
            XCTAssertEqual(r1?.id, created.id)
            clock.t.addTimeInterval(4 * 60)
            let r2 = try await s.resolve(token: token)
            XCTAssertNotNil(r2)
            clock.t.addTimeInterval(61) // 5 min 1 s after creation: polling did not extend
            let r3 = try await s.resolve(token: token)
            XCTAssertNil(r3)
            let none = try await s.resolve(token: "AAAA")
            XCTAssertNil(none)
        }
    }

    func testTokenIsStoredOnlyAsHash() async throws {
        try await DBFixture.with { f in
            let s = service(f, Clock())
            let (token, _) = try await s.createAnonymous()
            let n = try await f.sql.raw("SELECT COUNT(*) AS c FROM sessions WHERE token_hash = \(bind: Blob(Data(SHA256.hash(data: Data("form-session-v2|internal|".utf8) + Data(base64URLToken: token)!))))").first(decoding: C.self)?.c
            XCTAssertEqual(n, 1)
            let leaked = try await f.sql.raw("SELECT COUNT(*) AS c FROM sessions WHERE token_hash = \(bind: Blob(Data(base64URLToken: token)!))").first(decoding: C.self)?.c
            XCTAssertEqual(leaked, 0)
        }
    }

    func testRotationRevokesOldSessionAndChallengesAndAllowsNewToken() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = service(f, clock)
            let account = try await f.account()
            let (oldToken, old) = try await s.createAnonymous()
            let oldCsrf = try await s.csrfToken(for: old)
            try await f.sql.raw("""
                INSERT INTO auth_challenges (id, session_id, purpose, challenge_hash, factor_method, created_at, expires_at)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(old.id)), 'passkey-login', \(bind: Blob(Data(repeating: 1, count: 32))), 'passkey',
                  '2026-10-30 12:00:00.000000', '2026-10-30 12:01:00.000000')
                """).run()
            let (newToken, pending) = try await s.rotate(from: old, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 3)
            XCTAssertEqual(pending.state, .factorPending)
            let oldResolved = try await s.resolve(token: oldToken)
            XCTAssertNil(oldResolved)
            let newResolved = try await s.resolve(token: newToken)
            XCTAssertEqual(newResolved?.accountID, account)
            let revoked = try await f.sql.raw("SELECT COUNT(*) AS c FROM auth_challenges WHERE session_id = \(bind: DB.bin(old.id)) AND revoked_at IS NOT NULL").first(decoding: C.self)?.c
            XCTAssertEqual(revoked, 1)
            // CSRF is per session and must change on rotation
            let newCsrf = try await s.csrfToken(for: pending)
            XCTAssertNotEqual(oldCsrf, newCsrf)
            let sameOld = try await s.verifyCSRF(oldCsrf, for: pending)
            XCTAssertFalse(sameOld)
            // authenticated: idle window slides but is capped by the absolute limit
            let (authToken, auth) = try await s.rotate(from: pending, to: .authenticated, accountID: account, method: "passkey+password", rightsVersion: 3)
            XCTAssertEqual(auth.state, .authenticated)
            clock.t.addTimeInterval(29 * 60)
            let slid = try await s.resolve(token: authToken)
            XCTAssertNotNil(slid)
            clock.t.addTimeInterval(29 * 60)
            let stillOk = try await s.resolve(token: authToken)
            XCTAssertNotNil(stillOk)
            clock.t.addTimeInterval(31 * 60)
            let idleGone = try await s.resolve(token: authToken)
            XCTAssertNil(idleGone)
        }
    }

    func testRotationConsumesThePredecessorExactlyOnce() async throws {
        try await DBFixture.with { f in
            let s = service(f, Clock())
            let account = try await f.account()
            let (_, anon) = try await s.createAnonymous()
            // two parallel rotations of the same predecessor: one wins, the other fails and leaves no second session behind
            async let a: Bool = { (try? await s.rotate(from: anon, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 1)) != nil }()
            async let b: Bool = { (try? await s.rotate(from: anon, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 1)) != nil }()
            let results = await [a, b]
            XCTAssertEqual(results.filter { $0 }.count, 1)
            struct C: Decodable { let c: Int }
            let live = try await f.sql.raw("SELECT COUNT(*) AS c FROM sessions WHERE account_id = \(bind: DB.bin(account)) AND revoked_at IS NULL").first(decoding: C.self)?.c
            XCTAssertEqual(live, 1)
            // a revoked predecessor cannot be rotated at all
            do { _ = try await s.rotate(from: anon, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 1); XCTFail("a consumed predecessor must not rotate") } catch {}
        }
    }

    func testCSRFAcceptsOnlyTheSessionsToken() async throws {
        try await DBFixture.with { f in
            let s = service(f, Clock())
            let (_, a) = try await s.createAnonymous()
            let (_, b) = try await s.createAnonymous()
            let ta = try await s.csrfToken(for: a)
            let ok = try await s.verifyCSRF(ta, for: a)
            XCTAssertTrue(ok)
            for bad: String? in [nil, "", "x", try await s.csrfToken(for: b)] {
                let v = try await s.verifyCSRF(bad, for: a)
                XCTAssertFalse(v)
            }
            // sealed secret is useless under another server key
            let other = service(f, Clock(), key: try StaticServerKey(Data(repeating: 9, count: 32)))
            let t = try await other.csrfToken(for: a)
            XCTAssertNil(t)
        }
    }

    func testServerKeyMustBe32Bytes() {
        XCTAssertThrowsError(try StaticServerKey(Data(repeating: 1, count: 31)))
        XCTAssertNoThrow(try StaticServerKey(Data(repeating: 1, count: 32)))
    }
}
