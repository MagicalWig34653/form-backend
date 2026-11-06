// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
@testable import FormAuth

final class ThrottleDBTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_793_012_400); func now() -> Date { t } }
    private let key = try! StaticServerKey(Data(repeating: 7, count: 32))
    private struct C: Decodable { let c: Int }

    private func svc(_ f: DBFixture, _ clock: Clock) -> ThrottleService { ThrottleService(db: f.app.db(.mysql), keys: key, now: { clock.now() }) }
    private func retryAfter(_ body: () async throws -> Void) async -> Int? {
        do { try await body(); return nil } catch let e as RateLimited { return e.retryAfter } catch { return -1 }
    }

    func testBackoffThenLockAtLimitAndExpiry() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = svc(f, clock)
            let p = FailurePolicy.passwordPerAccount
            for _ in 1...2 { try await s.recordFailure(.account, "a", policy: p) }
            let none = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertNil(none)                                    // failures 1,2: no backoff yet
            try await s.recordFailure(.account, "a", policy: p)   // 3rd: 1 s
            var ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertEqual(ra, 1)
            clock.t.addTimeInterval(1.1)
            ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertNil(ra)
            try await s.recordFailure(.account, "a", policy: p)   // 4th: 2 s
            ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertEqual(ra, 2)
            clock.t.addTimeInterval(2.1)
            try await s.recordFailure(.account, "a", policy: p)   // 5th: lock 15 min
            ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertEqual(ra, 900)
            clock.t.addTimeInterval(400)
            ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }  // polling does not extend the lock
            XCTAssertEqual(ra, 500)
            clock.t.addTimeInterval(501)
            ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertNil(ra)
        }
    }

    func testSubjectsAndScopesAreIndependentAndStoredOnlyAsHMAC() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = svc(f, clock)
            let p = FailurePolicy(limit: 2, window: 900, lock: 60, backoff: false)
            try await s.recordFailure(.account, "alice", policy: p)
            try await s.recordFailure(.account, "alice", policy: p)
            var ra = await retryAfter { try await s.ensureNotLocked(.account, "alice") }
            XCTAssertEqual(ra, 60)
            ra = await retryAfter { try await s.ensureNotLocked(.account, "bob") }
            XCTAssertNil(ra)
            ra = await retryAfter { try await s.ensureNotLocked(.ip, "alice") }
            XCTAssertNil(ra)
            // unknown subjects are throttled exactly like known ones (no existence oracle)
            try await s.recordFailure(.account, "nobody-exists", policy: p)
            try await s.recordFailure(.account, "nobody-exists", policy: p)
            let ra2 = await retryAfter { try await s.ensureNotLocked(.account, "nobody-exists") }
            XCTAssertEqual(ra2, 60)
            let plain = try await f.sql.raw("SELECT COUNT(*) AS c FROM auth_throttles WHERE subject_hmac = \(bind: Blob(Data("alice".utf8)))").first(decoding: C.self)?.c
            XCTAssertEqual(plain, 0)
        }
    }

    func testClearResetsOnlyTheGivenSubject() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = svc(f, clock)
            let p = FailurePolicy(limit: 2, window: 900, lock: 60, backoff: false)
            for k in ["a", "b"] { try await s.recordFailure(.account, k, policy: p); try await s.recordFailure(.account, k, policy: p) }
            try await s.clear(.account, "a")
            var ra = await retryAfter { try await s.ensureNotLocked(.account, "a") }
            XCTAssertNil(ra)
            ra = await retryAfter { try await s.ensureNotLocked(.account, "b") }
            XCTAssertEqual(ra, 60)
        }
    }

    func testRequestBudgetCountsEveryCallAndResetsWithTheWindow() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); clock.t = Date(timeIntervalSince1970: 1_793_012_400 - 1_793_012_400.truncatingRemainder(dividingBy: 60) + 10) // 10 s into a window
            let s = svc(f, clock)
            for _ in 1...3 { try await s.consume(.adminRoute, "ip1", limit: 3, window: 60) }
            let ra = await retryAfter { try await s.consume(.adminRoute, "ip1", limit: 3, window: 60) }
            XCTAssertEqual(ra, 50)
            let other = await retryAfter { try await s.consume(.adminRoute, "ip2", limit: 3, window: 60) }
            XCTAssertNil(other)
            clock.t.addTimeInterval(51)
            let again = await retryAfter { try await s.consume(.adminRoute, "ip1", limit: 3, window: 60) }
            XCTAssertNil(again)
        }
    }

    func testConcurrentFailuresAreAllCounted() async throws {
        try await DBFixture.with { f in
            let clock = Clock(); let s = svc(f, clock)
            let p = FailurePolicy(limit: 10, window: 900, lock: 60, backoff: false)
            await withTaskGroup(of: Void.self) { g in
                for _ in 0..<10 { g.addTask { try? await s.recordFailure(.account, "race", policy: p) } }
            }
            let ra = await retryAfter { try await s.ensureNotLocked(.account, "race") }
            XCTAssertEqual(ra, 60, "10 parallel failures must reach the limit")
        }
    }
}
