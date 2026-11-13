// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAuth

final class AuthMaintenanceDBTests: XCTestCase {
    private struct C: Decodable { let c: Int }
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_793_012_400); func now() -> Date { t } }

    private func count(_ f: DBFixture, _ table: String) async throws -> Int {
        try await f.sql.raw("SELECT COUNT(*) AS c FROM \(unsafeRaw: table)").first(decoding: C.self)?.c ?? -1
    }

    func testPurgesOnlyOldEndedRowsAndKeepsReferencedAndLiveOnes() async throws {
        try await DBFixture.with { f in
            let clock = Clock()
            let sessions = SessionService(db: f.app.db(.mysql), keys: key, now: { clock.now() })
            let throttles = ThrottleService(db: f.app.db(.mysql), keys: key, now: { clock.now() })
            let account = try await f.account()

            // t0: an abandoned anonymous session and a rotated chain anon -> pending -> authenticated
            let (_, abandoned) = try await sessions.createAnonymous()
            let (_, anon) = try await sessions.createAnonymous()
            let (_, pending) = try await sessions.rotate(from: anon, to: .factorPending, accountID: account, method: "passkey", rightsVersion: 0)
            let (_, auth) = try await sessions.rotate(from: pending, to: .authenticated, accountID: account, method: "passkey+password", rightsVersion: 0)
            try await throttles.recordFailure(.account, "a", policy: FailurePolicy(limit: 1, window: 900, lock: 60, backoff: false))
            let n_sessions_4 = try await count(f, "sessions"); XCTAssertEqual(n_sessions_4, 4)

            // within the retention nothing is removed
            clock.t.addTimeInterval(6 * 86_400)
            var r = try await AuthMaintenance.purgeExpired(db: f.app.db(.mysql), now: clock.t)
            XCTAssertEqual(r.sessions, 0)
            XCTAssertEqual(r.throttles, 1)   // throttle windows are not retained for audit

            // a later "live" session must survive; the old ones go (oldest of the chain first, across passes)
            let (liveToken, live) = try await sessions.createAnonymous()
            clock.t.addTimeInterval(2 * 86_400)  // 8 d after t0: past 12 h session lifetime + 7 d retention
            r = try await AuthMaintenance.purgeExpired(db: f.app.db(.mysql), now: clock.t)
            XCTAssertGreaterThanOrEqual(r.sessions, 1)
            for _ in 0..<4 { _ = try await AuthMaintenance.purgeExpired(db: f.app.db(.mysql), now: clock.t) }   // peel the chain
            let remaining = try await f.sql.raw("SELECT id FROM sessions").all(decoding: SessionIDRow.self).compactMap { DB.uuid($0.id.data) }
            XCTAssertEqual(remaining, [live.id], "only the session newer than the cutoff remains")
            _ = (abandoned, auth, liveToken)
            let n_auth_challenges_0 = try await count(f, "auth_challenges"); XCTAssertEqual(n_auth_challenges_0, 0)
        }
    }

    func testNeverDeletesSessionsReferencedByConfirmations() async throws {
        try await DBFixture.with { f in
            let clock = Clock()
            let sessions = SessionService(db: f.app.db(.mysql), keys: key, now: { clock.now() })
            let account = try await f.account()
            let (_, anon) = try await sessions.createAnonymous()
            let (_, s) = try await sessions.rotate(from: anon, to: .authenticated, accountID: account, method: "x", rightsVersion: 0)
            // minimal referencing row (FK checks off only for this synthetic insert on one pinned connection)
            try await f.sql.withSession { c in
                try await c.raw("SET FOREIGN_KEY_CHECKS=0").run()
                try await c.raw("""
                    INSERT INTO publication_confirmations (id, session_id, account_id, customer_id, form_id, draft_id, draft_revision, candidate_sha256, authenticated_at, created_at, expires_at)
                    VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(s.id)), \(bind: DB.bin(account)), \(bind: DB.bin(UUID())), \(bind: DB.bin(UUID())), \(bind: DB.bin(UUID())), 1,
                      \(bind: Blob(Data(repeating: 1, count: 32))), '2026-10-30 12:00:00.000000', '2026-10-30 12:00:00.000000', '2026-10-30 13:00:00.000000')
                    """).run()
                try await c.raw("SET FOREIGN_KEY_CHECKS=1").run()
            }
            clock.t.addTimeInterval(30 * 86_400)
            for _ in 0..<3 { _ = try await AuthMaintenance.purgeExpired(db: f.app.db(.mysql), now: clock.t) }
            let still = try await f.sql.raw("SELECT COUNT(*) AS c FROM sessions WHERE id = \(bind: DB.bin(s.id))").first(decoding: C.self)?.c
            XCTAssertEqual(still, 1)
        }
    }

    private struct SessionIDRow: Decodable { let id: Blob }
}

final class AuthMaintenanceLeaderTests: XCTestCase {
    func testOnlyOneReplicaPurgesAtATime() async throws {
        try await DBFixture.with { f in
            let db = f.app.db(.mysql)
            // A second "replica" holds the lock on its own connection: this one must skip instead of waiting.
            struct L: Decodable { let l: Int? }
            try await f.sql.withSession { other in
                let got = try await other.raw("SELECT GET_LOCK(\(literal: AuthMaintenance.lockName), 0) AS l").first(decoding: L.self)?.l
                XCTAssertEqual(got, 1)
                let skipped = try await AuthMaintenance.purgeIfLeader(db: db, now: Date())
                XCTAssertNil(skipped)
                _ = try await other.raw("SELECT RELEASE_LOCK(\(literal: AuthMaintenance.lockName))").run()
            }
            let ran = try await AuthMaintenance.purgeIfLeader(db: db, now: Date())
            XCTAssertNotNil(ran)
        }
    }
}
