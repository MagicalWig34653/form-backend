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

    // MARK: review findings (Codex, S2-03a/b/c)

    /// Compiler budget: nested empty/zero repetitions must be refused or simplified quickly, never spin (S2-03a).
    func testCompilerWorkIsBounded() {
        for p in ["(((){1000}){1000}){1000}", "((((){1000}){1000}){1000}){1000}", "(((a{0}){1000}){1000}){1000}", "(((|){1000}){1000}){1000}",
                  "(((a?){1000}){1000}){1000}", "((a{1000}){1000}){1000}"] {
            within(5, p) { _ = try? LinearRegex(p); return false }
        }
        XCTAssertNotNil(LinearRegex.validate("((a{1000}){1000}){1000}"))
        XCTAssertNotNil(LinearRegex.validate("(((a?){1000}){1000}){1000}"))
        XCTAssertTrue(m("(){5}a", "a"))
    }

    /// Class set operators must not turn into a union of literals (S2-03b): `[a-z&&def]+` must never accept "abc".
    func testClassSetOperatorsAreRejected() {
        for p in ["[a-z&&def]+", "[a-z&&[^b]]", "[\\w--a]", "[a-z--b]", "[a||b]", "[[a-z]&&[def]]", "[[:alpha:]]", "[]a]", "[]", "[^]a]"] {
            XCTAssertNotNil(LinearRegex.validate(p), p)
        }
        XCTAssertNil(LinearRegex.validate("[a&b]")); XCTAssertNil(LinearRegex.validate("[a-]")); XCTAssertNil(LinearRegex.validate("[-a]")); XCTAssertNil(LinearRegex.validate("[a|b]"))
    }

    private func icu(_ p: String, _ s: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "^(?:" + p + ")\\z") else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Differential test against ICU with harmless patterns and short inputs, including negated classes.
    func testDifferentialAgainstICU() {
        let patterns = ["[a-c]+", "[^a-c]+", "[a-c\\d]+", "[^\\d]+", "[\\w]+", "[^\\w]+", "\\w+", "\\W+", "\\s+", "\\S+", "\\d+", "\\D+", "[\\W]+", "[^\\W]+", "[\\s\\d]+",
                        "a.c", "(ab|a)(bc|c)?", "x{2,4}", "[a&b]+", "[a-]+", "[-a]+", "[a|b]+", "[+.\\-]+", "(?:ab)*c?"]
        let inputs = ["", "a", "abc", "abcd", "ABC", "123", "a1", "a b", " ", "\t", "\n", "a\n", "_", "-", "&", "|", "ab", "xx", "xxxxx", "x", "über", "٣٤", "a\u{200C}b", "\u{200C}", "\u{200D}", "\u{203F}", "\u{0301}", "\u{00A0}",
                      "\u{2028}", "\u{0085}", "\u{000B}", "\u{3000}", "日本", "😀", "a.c", "a-c", "+.-"]
        for p in patterns { for s in inputs { XCTAssertEqual(m(p, s), icu(p, s), "pattern \(p) input \(s.unicodeScalars.map { $0.value })") } }
    }

    /// \w, \d, \s membership equals ICU's over BMP and plane 1 (S2-03c), also as negation.
    func testClassMembershipMatchesICU() {
        let res = ["\\w", "\\d", "\\s", "\\W", "\\D", "\\S", "[^\\w]", ".", "[^a]"].map { ($0, try! LinearRegex($0), try! NSRegularExpression(pattern: "^(?:" + $0 + ")\\z")) }
        var diffs: [String] = []
        for v in UInt32(0)...0x1FFFF {
            guard let sc = Unicode.Scalar(v), !(0xE000...0xF8FF).contains(v), let age = sc.properties.age, age.major <= 13 else { continue }   // private use and newer scalars: Unicode data of the platform ICU differs from the Swift stdlib
            let str = String(Character(sc))
            for (p, mine, ref) in res where mine.fullMatch(str) != (ref.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil) {
                if diffs.count < 10 { diffs.append("\(p) U+\(String(v, radix: 16))") }
            }
        }
        XCTAssertEqual(diffs, [])
        XCTAssertTrue(m("\\w", "\u{200C}")); XCTAssertFalse(m("\\W+", "\u{200C}"))
    }
}

private final class ResultBox: @unchecked Sendable { var value = true }
