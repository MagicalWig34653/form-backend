// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

final class LinearRegexTests: XCTestCase {
    private func m(_ p: String, _ s: String) -> Bool { (try? LinearRegex(p))?.fullMatch(s) ?? false }

    func testLegitimatePatternsKeepWorking() {
        XCTAssertTrue(m("\\d{5}", "12345")); XCTAssertFalse(m("\\d{5}", "1234")); XCTAssertFalse(m("\\d{5}", "123456"))
        XCTAssertTrue(m("^-?[0-9]+([.,][0-9]+)?$", "-12,5")); XCTAssertFalse(m("^-?[0-9]+([.,][0-9]+)?$", "12,"))
        XCTAssertTrue(m("[a-f0-9]{64}", String(repeating: "a", count: 64)))
        XCTAssertTrue(m("(?:Herr|Frau|Divers)", "Frau")); XCTAssertFalse(m("(?:Herr|Frau)", "Fra"))
        XCTAssertTrue(m("[A-ZÄÖÜ][a-zäöüß]+( [A-Z][a-z]+)*", "Anna Maria"))
        XCTAssertTrue(m("[^@\\s]+@[^@\\s]+\\.[a-z]{2,}", "a@b.de")); XCTAssertFalse(m("[^@\\s]+@[^@\\s]+\\.[a-z]{2,}", "a b@c.de"))
        XCTAssertTrue(m("a.c", "abc")); XCTAssertFalse(m("a.c", "a\nc"))
        XCTAssertTrue(m("\\w+\\.\\w+", "über.größe")); XCTAssertFalse(m("[0-9]{3}", "123\n"))
        XCTAssertTrue(m("(a*)*", "")); XCTAssertTrue(m("x{2,}", "xxxx")); XCTAssertFalse(m("x{2,3}", "xxxx"))
    }

    func testUnsupportedConstructsAreRejectedAtCompile() {
        for p in ["(?=a)a", "(?!a)a", "(?<=a)a", "(?i)a", "(a)\\1", "a+?", "a*+", "\\bfoo", "\\p{L}", "(a", "a)", "[a", "*a", "a**", String(repeating: "a", count: 501), "(a{1000}){1000}", "a{1001}"] {
            XCTAssertNotNil(LinearRegex.validate(p), p)
        }
        XCTAssertNil(LinearRegex.validate("[a-z]+"))
    }

    /// Runs the body on a background thread; fails (instead of hanging the suite) when it exceeds the budget.
    private func within(_ seconds: Double, _ what: String, _ body: @escaping @Sendable () -> Bool) {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        DispatchQueue.global().async { result.value = body(); done.signal() }
        if done.wait(timeout: .now() + seconds) == .timedOut { XCTFail("\(what): exceeded \(seconds) s (ReDoS)") } else { XCTAssertFalse(result.value, what) }
    }

    func testCatastrophicShapesStayFast() {
        let bad = String(repeating: "a", count: 100) + "!"
        for p in ["((a|aa))+", "(a+)+$", "(a|a)*", "(a*)*b", "(a|aa)+$", "(.*a){20}"] {
            within(5, p) { (try? LinearRegex(p))?.fullMatch(bad) ?? false }
        }
        let long = String(repeating: "a", count: 1_990) + "!"
        within(5, "long input") { (try? LinearRegex("(a|aa)+"))?.fullMatch(long) ?? false }
        within(5, "oversized input") { (try? LinearRegex("a*"))?.fullMatch(String(repeating: "a", count: 5_000)) ?? false }
    }
}

private final class ResultBox: @unchecked Sendable { var value = true }
