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
        let c = try await budget.reserveWaiting(bodyBytes: size)
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
            let t = Date(); let r = try await budget.reserveWaiting(bodyBytes: size)
            XCTAssertNil(r, "\(size)"); XCTAssertLessThan(Date().timeIntervalSince(t), 0.5, "\(size) must not wait")
        }
        XCTAssertEqual(budget.waited, 0); XCTAssertEqual(budget.refused, 3)
        // below the threshold that does fit is still granted at once
        let free = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let ok = try await free.reserveWaiting(bodyBytes: mib)
        XCTAssertNotNil(ok)
        held.release()
    }

    func testBodiesOfFourMiBAndMoreStillWait() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
        Task { try? await Task.sleep(nanoseconds: 200_000_000); held.release() }
        let r = try await budget.reserveWaiting(bodyBytes: 4 * mib)
        XCTAssertNotNil(r); XCTAssertEqual(budget.waited, 1)
        r?.release(); XCTAssertEqual(budget.inFlight, 0)
    }

    func testWaitingTimesOutWithNilAndZeroWaitRefusesAtOnce() async throws {
        let busy = BodyBudget(capacity: 64 * mib, maxWait: 0.2)
        let held = try XCTUnwrap(busy.reserve(bodyBytes: 64 * mib))
        let start = Date()
        let r = try await busy.reserveWaiting(bodyBytes: 10 * mib)
        XCTAssertNil(r); XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.15)
        held.release()
        XCTAssertEqual(busy.inFlight, 0)
        let none = BodyBudget(capacity: 64 * mib)   // maxWait 0
        let h2 = try XCTUnwrap(none.reserve(bodyBytes: 64 * mib))
        let t = Date(); let r2 = try await none.reserveWaiting(bodyBytes: 1)
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
                    if let l = try? await budget.reserveWaiting(bodyBytes: 30 * 1024 * 1024) {
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

    // MARK: cancel while queued (card 01480C4B)

    private func waitUntil(_ what: String, timeout: TimeInterval = 5, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() { if Date() > end { XCTFail("timeout: \(what)"); return }; try await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testCancelledWaitingTaskIsRemovedAndNothingStaysReserved() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))   // 60 of 64 MiB
        let task = Task { try await budget.reserveWaiting(bodyBytes: 6 * mib) }
        try await waitUntil("queued") { budget.waiting == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("must throw") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(budget.waiting, 0); XCTAssertEqual(budget.cancelled, 1)
        XCTAssertEqual(budget.inFlight, 60 * mib, "only the occupying lease")
        XCTAssertEqual(budget.granted, 1, "the abandoned request was never admitted")
        held.release()
        XCTAssertEqual(budget.inFlight, 0, "no reservation was made for the abandoned request, not even after the release")
        XCTAssertEqual(budget.granted, 1)
    }

    func testAlreadyCancelledTaskDoesNotQueueAtAll() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await budget.reserveWaiting(bodyBytes: 6 * mib); return false } catch { return error is CancellationError }
        }
        let threw = await task.value
        XCTAssertTrue(threw); XCTAssertEqual(budget.waiting, 0); XCTAssertEqual(budget.waited, 0)
        held.release(); XCTAssertEqual(budget.inFlight, 0)
    }

    func testAbandonedPredicateRemovesTheWaiterAndKeepsFIFOOrderOfTheOthers() async throws {
        let budget = BodyBudget(capacity: 90 * mib, maxWait: 30)
        let first = try XCTUnwrap(budget.reserve(bodyBytes: 30 * mib))   // fills it
        let gone = AtomicFlag()
        let order = OrderLog()
        async let a: Void = { if let l = try? await budget.reserveWaiting(bodyBytes: 30 * mib) { await order.add(0); l.release() } }()
        try await waitUntil("a queued") { budget.waiting == 1 }
        async let b: Void = {
            do { _ = try await budget.reserveWaiting(bodyBytes: 30 * mib, abandoned: { gone.value }); await order.add(1) } catch { await order.add(-1) }
        }()
        try await waitUntil("b queued") { budget.waiting == 2 }
        async let c: Void = { if let l = try? await budget.reserveWaiting(bodyBytes: 30 * mib) { await order.add(2); l.release() } }()
        try await waitUntil("c queued") { budget.waiting == 3 }
        gone.value = true   // the second client disconnects while queued
        try await waitUntil("b removed") { budget.waiting == 2 }
        XCTAssertEqual(budget.cancelled, 1); XCTAssertEqual(budget.inFlight, 90 * mib, "only the occupying lease (30 MiB x 3)")
        first.release()
        _ = try await (a, b, c)
        let seen = await order.items
        XCTAssertEqual(seen.filter { $0 >= 0 }, [0, 2], "the others are served in arrival order; the abandoned one never"); XCTAssertTrue(seen.contains(-1))
        XCTAssertEqual(budget.inFlight, 0); XCTAssertEqual(budget.waiting, 0)
        XCTAssertEqual(budget.granted, 3, "holder + the two live waiters")
    }

    /// The head of the queue is the abandoned one and blocks smaller followers: once it leaves, the followers must be admitted (drain).
    func testRemovingTheBlockingHeadAdmitsTheFollowers() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 10 * mib))   // 30 of 64 MiB, 34 free
        let head = Task { try await budget.reserveWaiting(bodyBytes: 20 * mib) }   // cost 60: does not fit
        try await waitUntil("head queued") { budget.waiting == 1 }
        let follower = Task { try await budget.reserveWaiting(bodyBytes: 4 * mib) }   // cost 12: would fit but queues behind the head
        try await waitUntil("follower queued") { budget.waiting == 2 }
        head.cancel()
        let lease = try await follower.value
        XCTAssertNotNil(lease, "admitted as soon as the abandoned head is gone")
        XCTAssertEqual(budget.inFlight, 30 * mib + 12 * mib)
        _ = try? await head.value
        lease?.release(); held.release(); XCTAssertEqual(budget.inFlight, 0)
    }

    func testLeaseRecordsWhetherItHadToWait() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 5)
        let immediate = try await budget.reserveWaiting(bodyBytes: 5 * mib)
        XCTAssertEqual(immediate?.waited, false)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 15 * mib))   // 45 + 15 = 60
        Task { try? await Task.sleep(nanoseconds: 100_000_000); immediate?.release(); held.release() }
        let queued = try await budget.reserveWaiting(bodyBytes: 20 * mib)
        XCTAssertEqual(queued?.waited, true); queued?.release()
    }

    func testManyCancellationsLeaveNoLeak() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
        var tasks: [Task<Bool, Error>] = []
        for _ in 0..<50 {
            tasks.append(Task {
                guard let lease = try await budget.reserveWaiting(bodyBytes: 5 * mib) else { return false }
                try await Task.sleep(nanoseconds: 1_000_000); lease.release(); return true
            })
        }
        try await waitUntil("all queued") { budget.waiting == 50 }
        for (i, t) in tasks.enumerated() where i % 2 == 0 { t.cancel() }
        try await waitUntil("half removed") { budget.waiting == 25 }
        held.release()
        var admitted = 0
        for (i, t) in tasks.enumerated() {
            if let ok = try? await t.value, ok { admitted += 1; XCTAssertTrue(i % 2 == 1) }
        }
        XCTAssertEqual(admitted, 25); XCTAssertEqual(budget.cancelled, 25)
        XCTAssertEqual(budget.inFlight, 0); XCTAssertEqual(budget.waiting, 0)
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

final class AtomicFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}
private actor OrderLog { var items: [Int] = []; func add(_ n: Int) { items.append(n) } }
