// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormMail

/// EE0E1DD9: the byte reservation that guards manual resends with attachments.
final class ResendMemoryBudgetTests: XCTestCase {
    func testReservationNeverBlocksNeverExceedsLimitAndReleases() async {
        let b = MailDispatcher.MemoryBudget(limit: 100)
        let r1 = await b.tryReserve(60), r2 = await b.tryReserve(41), r3 = await b.tryReserve(40)
        XCTAssertTrue(r1); XCTAssertFalse(r2, "over the limit: refused at once, not queued"); XCTAssertTrue(r3)
        let full = await b.reserved; XCTAssertEqual(full, 100)
        await b.release(60)
        let again = await b.tryReserve(60); XCTAssertTrue(again)
        await b.release(1_000)   // over-release never goes negative
        let zero = await b.reserved; XCTAssertEqual(zero, 0)
        let neg = await b.tryReserve(-1); XCTAssertFalse(neg)
    }

    func testParallelReservationsStayWithinTheLimit() async {
        let b = MailDispatcher.MemoryBudget(limit: 1_000)
        let granted = await withTaskGroup(of: Int.self) { g in
            for _ in 0..<200 { g.addTask { await b.tryReserve(100) ? 100 : 0 } }
            return await g.reduce(0, +)
        }
        XCTAssertEqual(granted, 1_000)
        let reserved = await b.reserved; XCTAssertEqual(reserved, 1_000)
    }
}
