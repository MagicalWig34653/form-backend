// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormMail

final class MailShortenTests: XCTestCase {
    func testShortenCutsOnCharacterBoundaryAndAddsNote() throws {
        let long = String(repeating: "ä", count: 1000)   // 2 bytes each
        let (out, changed) = MailTemplate.shorten(["a": long, "b": "kurz"], maxBytesPerValue: 101)
        XCTAssertTrue(changed)
        XCTAssertEqual(out["b"], "kurz")
        let a = try XCTUnwrap(out["a"])
        XCTAssertTrue(a.hasSuffix(MailTemplate.shortenedNote))
        XCTAssertTrue(a.hasPrefix(String(repeating: "ä", count: 50)))
        XCTAssertLessThanOrEqual(a.utf8.count, 101 + MailTemplate.shortenedNote.utf8.count)
    }

    func testShortenLeavesSmallValuesUntouched() {
        let (out, changed) = MailTemplate.shorten(["a": "x"], maxBytesPerValue: 10)
        XCTAssertFalse(changed); XCTAssertEqual(out, ["a": "x"])
    }

    private func build(_ v: [String: String]) throws -> MailMessage {
        try MailMessage(fromAddress: "a@example.invalid", to: ["t@example.invalid"], subject: "S",
                        body: MailTemplate.render("#=[n]=#", values: v, html: false), isHTML: false)
    }

    func testOversizedMessageBecomesShortenedMessage() throws {
        let values = ["n": String(repeating: "x", count: 30 << 20)]
        XCTAssertThrowsError(try build(values).rfc822())
        let (message, shortened) = try MailTemplate.buildShorteningIfTooLarge(values: values, build: build)
        XCTAssertTrue(shortened)
        XCTAssertLessThanOrEqual(try message.rfc822().count, MailMessage.maxBytes)
        XCTAssertTrue(message.body.contains(MailTemplate.shortenedNote))
    }

    func testSmallMessageIsNotShortened() throws {
        let (_, shortened) = try MailTemplate.buildShorteningIfTooLarge(values: ["n": "hallo"], build: build)
        XCTAssertFalse(shortened)
    }
}
