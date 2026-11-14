// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

/// Byte budget for request bodies in flight (fb-sec findings 1 and 2); DB-free.
final class BodyBudgetTests: XCTestCase {
    private let mib = 1 << 20

    func testReservesTheFactorTimesTheBodyAndRefusesWhatDoesNotFit() throws {
        let budget = BodyBudget(capacity: 100 * mib)
        let a = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))   // 60 MiB
        XCTAssertEqual(budget.inFlight, 20 * mib * BodyBudget.memoryFactor)
        XCTAssertNil(budget.reserve(bodyBytes: 20 * mib), "second 60 MiB does not fit into 100 MiB")
        let b = try XCTUnwrap(budget.reserve(bodyBytes: 10 * mib))   // 30 MiB, 90 in total
        XCTAssertEqual(budget.inFlight, 90 * mib)
        XCTAssertNil(budget.reserve(bodyBytes: 4 * mib), "12 MiB would exceed 100 MiB")
        a.release()
        XCTAssertEqual(budget.inFlight, 30 * mib)
        XCTAssertNotNil(budget.reserve(bodyBytes: 20 * mib))
        b.release()
        XCTAssertEqual(budget.refused, 2)
    }

    func testReleaseIsIdempotentAndHappensWhenTheLeaseIsDropped() throws {
        let budget = BodyBudget(capacity: 100 * mib)
        let a = try XCTUnwrap(budget.reserve(bodyBytes: 10 * mib))
        a.release(); a.release()
        XCTAssertEqual(budget.inFlight, 0)
        do { let held = try XCTUnwrap(budget.reserve(bodyBytes: 10 * mib)); _ = held; XCTAssertEqual(budget.inFlight, 30 * mib) }
        XCTAssertEqual(budget.inFlight, 0, "a dropped lease (error path) gives the bytes back")
        XCTAssertEqual(budget.peak, 30 * mib)
    }

    func testEmptyBodiesCostNothingAndOversizedBodiesRunAlone() throws {
        let budget = BodyBudget(capacity: 64 * mib)
        let full = try XCTUnwrap(budget.reserve(bodyBytes: 64 * mib), "larger than the budget: clamped, runs alone")
        XCTAssertEqual(budget.inFlight, 64 * mib)
        XCTAssertNotNil(budget.reserve(bodyBytes: 0), "no body, no cost")
        XCTAssertNil(budget.reserve(bodyBytes: 1))
        full.release()
        let big = try XCTUnwrap(budget.reserve(bodyBytes: Int.max))
        XCTAssertEqual(budget.inFlight, 64 * mib, "no overflow")
        big.release()
    }

    func testConcurrentReservationsNeverExceedTheCapacity() async throws {
        let budget = BodyBudget(capacity: 192 * mib)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    for _ in 0..<200 {
                        if let l = budget.reserve(bodyBytes: 30 * 1024 * 1024) { XCTAssertLessThanOrEqual(budget.inFlight, 192 * 1024 * 1024); l.release() }
                    }
                }
            }
        }
        XCTAssertEqual(budget.inFlight, 0)
        XCTAssertLessThanOrEqual(budget.peak, 192 * mib)
    }

    /// Card B0D216F2: three parallel 19.5 MB bodies cost 3 x 58.5 MiB against 128 MiB; the third must wait, not fail.
    func testThirdParallelLargeBodyWaitsForCapacityInsteadOfBeingRefused() async throws {
        let budget = BodyBudget(capacity: BodyBudget.defaultCapacity, maxWait: 5)
        let size = Int(19.5 * Double(mib))
        let a = try XCTUnwrap(budget.reserve(bodyBytes: size)), b = try XCTUnwrap(budget.reserve(bodyBytes: size))
        XCTAssertNil(budget.reserve(bodyBytes: size), "the immediate path still refuses")
        Task { try? await Task.sleep(nanoseconds: 200_000_000); a.release() }
        let c = await budget.reserveWaiting(bodyBytes: size)
        XCTAssertNotNil(c, "admitted once the first upload finished")
        XCTAssertEqual(budget.waited, 1)
        XCTAssertLessThanOrEqual(budget.peak, budget.capacity)
        b.release(); c?.release()
        XCTAssertEqual(budget.inFlight, 0)
    }

    /// Card 85E16E07: bodies below 4 MiB never wait (they often sit completely in the socket buffer, an aborted client would be processed afterwards).
    func testBodiesBelowFourMiBAreRefusedAtOnceEvenWithAWaitWindow() async throws {
        XCTAssertEqual(BodyBudget.minWaitBytes, 4 * mib)
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))   // 60 of 64 MiB
        for size in [2 * mib, 3 * mib + mib / 2, 4 * mib - 1] {   // cost 3x exceeds the 4 MiB left
            let t = Date(); let r = await budget.reserveWaiting(bodyBytes: size)
            XCTAssertNil(r, "\(size)"); XCTAssertLessThan(Date().timeIntervalSince(t), 0.5, "\(size) must not wait")
        }
        XCTAssertEqual(budget.waited, 0); XCTAssertEqual(budget.refused, 3)
        // below the threshold that does fit is still granted at once
        let free = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let ok = await free.reserveWaiting(bodyBytes: mib)
        XCTAssertNotNil(ok)
        held.release()
    }

    func testBodiesOfFourMiBAndMoreStillWait() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
        Task { try? await Task.sleep(nanoseconds: 200_000_000); held.release() }
        let r = await budget.reserveWaiting(bodyBytes: 4 * mib)
        XCTAssertNotNil(r); XCTAssertEqual(budget.waited, 1)
        r?.release(); XCTAssertEqual(budget.inFlight, 0)
    }

    func testWaitingTimesOutWithNilAndZeroWaitRefusesAtOnce() async throws {
        let busy = BodyBudget(capacity: 64 * mib, maxWait: 0.2)
        let held = try XCTUnwrap(busy.reserve(bodyBytes: 64 * mib))
        let start = Date()
        let r = await busy.reserveWaiting(bodyBytes: 10 * mib)
        XCTAssertNil(r); XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.15)
        held.release()
        XCTAssertEqual(busy.inFlight, 0)
        let none = BodyBudget(capacity: 64 * mib)   // maxWait 0
        let h2 = try XCTUnwrap(none.reserve(bodyBytes: 64 * mib))
        let t = Date(); let r2 = await none.reserveWaiting(bodyBytes: 1)
        XCTAssertNil(r2); XCTAssertLessThan(Date().timeIntervalSince(t), 0.1); h2.release()
    }

    func testWaitersAreServedInArrivalOrderAndNeverExceedTheCapacity() async throws {
        let budget = BodyBudget(capacity: 90 * mib, maxWait: 10)
        let first = try XCTUnwrap(budget.reserve(bodyBytes: 30 * mib))   // fills it
        let order = OrderLog()
        await withTaskGroup(of: Void.self) { group in
            for n in 0..<4 {
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(n) * 50_000_000)
                    if let l = await budget.reserveWaiting(bodyBytes: 30 * 1024 * 1024) {
                        XCTAssertLessThanOrEqual(budget.inFlight, 90 * 1024 * 1024)
                        await order.add(n); try? await Task.sleep(nanoseconds: 20_000_000); l.release()
                    }
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: 400_000_000); first.release() }
        }
        let seen = await order.items
        XCTAssertEqual(seen, [0, 1, 2, 3])
        XCTAssertEqual(budget.inFlight, 0)
    }

    func testEnvironmentOverrideIsValidated() throws {
        let base = ["FORM_DB_PASSWORD": "x"]
        XCTAssertEqual(try AppConfig(env: base).bodyBudgetBytes, BodyBudget.defaultCapacity)
        XCTAssertEqual(try AppConfig(env: base.merging(["FORM_BODY_BUDGET_MB": "256"]) { $1 }).bodyBudgetBytes, 256 * mib)
        for bad in ["", "abc", "63", "8193", "-1", "1e3"] {
            XCTAssertThrowsError(try AppConfig(env: base.merging(["FORM_BODY_BUDGET_MB": bad]) { $1 }), bad)
        }
    }
}

private actor OrderLog { var items: [Int] = []; func add(_ n: Int) { items.append(n) } }
