// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormMail

final class MailMessageTests: XCTestCase {
    func testAddressParsingAcceptsPlainAndRejectsAnythingElse() {
        XCTAssertEqual(MailAddress.parse("  Max.Muster+tag@Example.ORG "), "Max.Muster+tag@example.org")
        for bad in ["", "a", "a@b", "a@b.c", "a@@b.de", "a b@c.de", "a@c .de", ".a@c.de", "a.@c.de", "a..b@c.de", "<a@c.de>", "Name <a@c.de>", "a@c.de, b@c.de", "a@c.de\r\nBcc: x@y.de",
                    "a@c.de\n", "ü@c.de", "a@ü.de", "a@-c.de", "a@c-.de", "a@c.d1", String(repeating: "a", count: 65) + "@c.de", "a@" + String(repeating: "b", count: 64) + ".de", "a@c.de\0", "\"a b\"@c.de", "a@[1.2.3.4]"] {
            XCTAssertNil(MailAddress.parse(bad), bad.debugDescription)
        }
    }

    private func message(_ f: (inout MailMessage) -> Void = { _ in }) throws -> MailMessage {
        var m = try MailMessage(fromAddress: "absender@example.org", fromName: "Müller & Söhne", to: ["a@example.org", "b@example.org"], bcc: ["geheim@example.org"], replyTo: "r@example.org",
                                subject: "Anfrage: Grüße 🌍", body: "Hallo\nZeile 2\n.Punkt\n", isHTML: false, date: Date(timeIntervalSince1970: 1_793_012_400))
        f(&m); return m
    }

    private func parse(_ data: Data) -> (headers: [String: String], body: String) {
        let text = String(decoding: data, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        var unfolded = parts[0].replacingOccurrences(of: "\r\n ", with: "")
        var h: [String: String] = [:]
        for l in unfolded.components(separatedBy: "\r\n") { if let c = l.firstIndex(of: ":") { h[String(l[..<c]).lowercased()] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces) } }
        unfolded = ""
        let b64 = parts.dropFirst().joined(separator: "\r\n\r\n").replacingOccurrences(of: "\r\n", with: "")
        return (h, String(decoding: Data(base64Encoded: b64) ?? Data(), as: UTF8.self))
    }

    func testWireFormatHeadersBodyAndBccPrivacy() throws {
        let data = try message().rfc822()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.lowercased().contains("bcc"), "Bcc recipients are envelope-only")
        XCTAssertFalse(text.contains("geheim@"))
        XCTAssertTrue(text.hasSuffix("\r\n")); XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "CRLF only")
        let (h, body) = parse(data)
        XCTAssertEqual(h["date"], "Mon, 26 Oct 2026 11:00:00 +0000")   // 1793012400 = 2026-10-26T11:00:00Z
        XCTAssertEqual(h["to"], "a@example.org, b@example.org"); XCTAssertEqual(h["reply-to"], "r@example.org")
        XCTAssertEqual(h["mime-version"], "1.0"); XCTAssertEqual(h["content-type"], "text/plain; charset=utf-8"); XCTAssertEqual(h["content-transfer-encoding"], "base64")
        XCTAssertTrue(h["message-id"]!.hasSuffix("@example.org>"))
        XCTAssertEqual(body, "Hallo\r\nZeile 2\r\n.Punkt\r\n")
        // encoded subject and display name decode back
        func decode(_ s: String) -> String {
            s.components(separatedBy: "=?UTF-8?B?").dropFirst().map { String(decoding: Data(base64Encoded: String($0.prefix(while: { $0 != "?" }))) ?? Data(), as: UTF8.self) }.joined()
        }
        XCTAssertTrue(decode(h["subject"]!).contains("Grüße 🌍"))
        XCTAssertTrue(decode(h["from"]!.components(separatedBy: " <")[0]).contains("Müller & Söhne"))
        XCTAssertTrue(h["from"]!.hasSuffix("<absender@example.org>"))
    }

    func testLongNonASCIISubjectsAreSplitIntoValidEncodedWords() throws {
        let m = try message { $0.subject = String(repeating: "Überschrift ✓ ", count: 30) }
        let raw = String(decoding: try m.rfc822(), as: UTF8.self)
        let subjectBlock = raw.components(separatedBy: "\r\nSubject: ")[1].components(separatedBy: "\r\nMessage-ID")[0]
        for word in subjectBlock.components(separatedBy: "\r\n ") { XCTAssertTrue(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="), word); XCTAssertLessThanOrEqual(word.count, 75) }
        for line in raw.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 998) }
        let decoded = subjectBlock.components(separatedBy: "\r\n ").map { w -> String in String(decoding: Data(base64Encoded: String(w.dropFirst(10).dropLast(2))) ?? Data(), as: UTF8.self) }.joined()
        XCTAssertEqual(decoded, String(repeating: "Überschrift ✓ ", count: 30), "characters are never cut in the middle of a multi-byte sequence")
    }

    func testASCIIDisplayNameIsQuotedAndInjectionIsImpossible() throws {
        let m = try message { $0.fromName = "Evil \"Quote\" \\ Name" }
        XCTAssertTrue(String(decoding: try m.rfc822(), as: UTF8.self).contains("From: \"Evil \\\"Quote\\\" \\\\ Name\" <absender@example.org>"))
        XCTAssertThrowsError(try MailMessage(fromAddress: "a@example.org", fromName: "x\r\nBcc: y@z.de", to: ["b@example.org"], subject: "s", body: "b", isHTML: false)) { XCTAssertEqual($0 as? MailError, .invalidHeader) }
        XCTAssertThrowsError(try MailMessage(fromAddress: "a@example.org", to: ["b@example.org"], subject: "s\r\nBcc: y@z.de", body: "b", isHTML: false)) { XCTAssertEqual($0 as? MailError, .invalidHeader) }
        XCTAssertThrowsError(try MailMessage(fromAddress: "a@example.org", to: ["b@example.org\r\nBcc: y@z.de"], subject: "s", body: "b", isHTML: false)) { XCTAssertEqual($0 as? MailError, .invalidAddress) }
        XCTAssertThrowsError(try MailMessage(fromAddress: "a@example.org", to: [], subject: "s", body: "b", isHTML: false)) { XCTAssertEqual($0 as? MailError, .noRecipients) }
        XCTAssertThrowsError(try MailMessage(fromAddress: "nope", to: ["b@example.org"], subject: "s", body: "b", isHTML: false))
    }

    func testHTMLFlagSizeLimitAndRecipientDeduplication() throws {
        XCTAssertTrue(String(decoding: try message { $0.isHTML = true }.rfc822(), as: UTF8.self).contains("Content-Type: text/html; charset=utf-8"))
        XCTAssertThrowsError(try message { $0.body = String(repeating: "x", count: MailMessage.maxBytes) }.rfc822()) { XCTAssertEqual($0 as? MailError, .tooLarge) }
        let m = try message { $0.bcc = ["A@example.org", "c@example.org"] }
        XCTAssertEqual(m.envelopeRecipients, ["a@example.org", "b@example.org", "c@example.org"])
    }
}

final class MailTemplateTests: XCTestCase {
    func testPlaceholdersLegacySyntaxAndUnknownStaysAsWritten() {
        let v = ["name": "Max", "nachricht": "Hi"]
        XCTAssertEqual(MailTemplate.render("Hallo #=[name]=#, #=[nachricht]=# #=[fehlt]=# #=[ name ]=# #[name]#", values: v, html: false), "Hallo Max, Hi #=[fehlt]=# #=[ name ]=# #[name]#")
    }

    func testHTMLValuesAreEscapedTextAndSubjectsAreNot() {
        let v = ["x": "<script>alert('1')</script> & \"q\""]
        XCTAssertEqual(MailTemplate.render("<p>#=[x]=#</p>", values: v, html: true), "<p>&lt;script&gt;alert(&#39;1&#39;)&lt;/script&gt; &amp; &quot;q&quot;</p>")
        XCTAssertEqual(MailTemplate.render("#=[x]=#", values: v, html: false), v["x"])
        // a value cannot inject markup through the template itself, and template markup is the admin's
        XCTAssertEqual(MailTemplate.render("#=[x]=#", values: ["x": "#=[y]=#", "y": "SECOND"], html: false), "#=[y]=#", "no recursive expansion")
    }

    func testSubjectStripsLineBreaksAndIsBounded() {
        XCTAssertEqual(MailTemplate.renderSubject("Neu: #=[n]=#", values: ["n": "a\r\nBcc: x@y.de\u{0}b"]), "Neu: a  Bcc: x@y.de b")
        XCTAssertEqual(MailTemplate.renderSubject(String(repeating: "x", count: 1000), values: [:]).count, 300)
    }

    func testFlatteningOfListsAndMapsAndNames() {
        let v = MailTemplate.values(fromFields: ["a": "1", "liste": ["x", "y"], "karte": ["k2": "2", "k1": "1"], "bad-name": "z", "n": "7"])
        XCTAssertEqual(v["liste"], "x, y"); XCTAssertEqual(v["karte"], "k1: 1, k2: 2"); XCTAssertNil(v["bad-name"]); XCTAssertEqual(v["n"], "7")
    }
}
