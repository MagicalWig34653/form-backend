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

    func testEnvironmentOverrideIsValidated() throws {
        let base = ["FORM_DB_PASSWORD": "x"]
        XCTAssertEqual(try AppConfig(env: base).bodyBudgetBytes, BodyBudget.defaultCapacity)
        XCTAssertEqual(try AppConfig(env: base.merging(["FORM_BODY_BUDGET_MB": "256"]) { $1 }).bodyBudgetBytes, 256 * mib)
        for bad in ["", "abc", "63", "8193", "-1", "1e3"] {
            XCTAssertThrowsError(try AppConfig(env: base.merging(["FORM_BODY_BUDGET_MB": bad]) { $1 }), bad)
        }
    }
}
