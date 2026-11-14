// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormMail

/// ADR 0049: team mails carry the uploaded files. Wire form, file names, limits.
final class MailAttachmentTests: XCTestCase {
    private func message(_ a: [MailAttachment], body: String = "Hallo\n.Punkt\n", html: Bool = false) throws -> MailMessage {
        try MailMessage(fromAddress: "absender@example.org", to: ["a@example.org"], subject: "Betreff", body: body, isHTML: html,
                        date: Date(timeIntervalSince1970: 1_793_012_400), attachments: a)
    }

    /// Minimal MIME reader for the tests: boundary, parts (headers unfolded, lower-cased names), decoded part bytes.
    private func parts(_ wire: Data) throws -> (top: [String: String], parts: [(headers: [String: String], bytes: Data)]) {
        let text = String(decoding: wire, as: UTF8.self)
        let top = text.components(separatedBy: "\r\n\r\n")[0]
        func headers(_ block: String) -> [String: String] {
            var h: [String: String] = [:]
            for l in block.replacingOccurrences(of: "\r\n ", with: "").components(separatedBy: "\r\n") { if let c = l.firstIndex(of: ":") { h[String(l[..<c]).lowercased()] = String(l[l.index(after: c)...]).trimmingCharacters(in: .whitespaces) } }
            return h
        }
        let topH = headers(top)
        let ct = try XCTUnwrap(topH["content-type"])
        let boundary = try XCTUnwrap(ct.components(separatedBy: "boundary=\"").last?.components(separatedBy: "\"").first)
        var out: [(headers: [String: String], bytes: Data)] = []
        let segments = text.components(separatedBy: "--\(boundary)")
        for seg in segments.dropFirst().dropLast() {
            let pieces = seg.dropFirst(1).components(separatedBy: "\r\n\r\n")   // CRLF is one Character
            let b64 = pieces.dropFirst().joined(separator: "\r\n\r\n").replacingOccurrences(of: "\r\n", with: "")
            out.append((headers(pieces[0]), Data(base64Encoded: b64) ?? Data()))
        }
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        return (topH, out)
    }

    private func pdf(_ n: Int, seed: UInt8 = 7) -> Data {
        var d = Data("%PDF-1.4\n".utf8)
        for i in 0..<(n - d.count) { d.append(UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed))) }
        return d
    }

    func testAttachmentIsByteIdenticalAndTextPartIsKept() throws {
        let file = pdf(100_000)
        let m = try message([MailAttachment(filename: "Überweisung.pdf", contentType: "application/pdf", data: file)])
        let p = try parts(m.rfc822())
        XCTAssertTrue(p.top["content-type"]!.hasPrefix("multipart/mixed"))
        XCTAssertEqual(p.parts.count, 2)
        XCTAssertEqual(String(decoding: p.parts[0].bytes, as: UTF8.self), "Hallo\r\n.Punkt\r\n")
        XCTAssertEqual(p.parts[1].bytes, file)
        XCTAssertEqual(p.parts[1].headers["content-type"]?.hasPrefix("application/pdf"), true)
        XCTAssertEqual(p.parts[1].headers["content-transfer-encoding"], "base64")
        XCTAssertTrue(p.parts[1].headers["content-disposition"]!.hasPrefix("attachment;"))
    }

    func testNoAttachmentKeepsTheSinglePartWireForm() throws {
        let wire = String(decoding: try message([]).rfc822(), as: UTF8.self)
        XCTAssertTrue(wire.contains("Content-Type: text/plain; charset=utf-8"))
        XCTAssertFalse(wire.lowercased().contains("multipart"))
    }

    func testSeveralAttachmentsKeepOrderAndBytes() throws {
        let a = pdf(5_000, seed: 1), b = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0xFF, count: 777)
        let m = try message([MailAttachment(filename: "a.pdf", contentType: "application/pdf", data: a), MailAttachment(filename: "b.png", contentType: "image/png", data: b)])
        let p = try parts(m.rfc822())
        XCTAssertEqual(p.parts.map(\.bytes), [Data("Hallo\r\n.Punkt\r\n".utf8), a, b])
        XCTAssertTrue(p.parts[2].headers["content-type"]!.hasPrefix("image/png"))
    }

    func testFilenameUmlautsAreRFC2231EncodedWithAsciiFallback() throws {
        let m = try message([MailAttachment(filename: "Überweisung Ärzte-äöüß; (1).pdf", contentType: "application/pdf", data: pdf(100))])
        let wire = String(decoding: try m.rfc822(), as: UTF8.self)
        XCTAssertTrue(wire.contains("filename=\"Ueberweisung Aerzte-aeoeuess; (1).pdf\""), wire)
        XCTAssertTrue(wire.contains("filename*=UTF-8''%C3%9Cberweisung%20%C3%84rzte-%C3%A4%C3%B6%C3%BC%C3%9F%3B%20%281%29.pdf"), wire)
        XCTAssertTrue(wire.contains("name*=UTF-8''%C3%9Cberweisung"))
        for line in wire.components(separatedBy: "\r\n") { XCTAssertTrue(line.utf8.allSatisfy { $0 < 0x80 }, "headers stay 7-bit") }
    }

    func testFilenameCannotInjectHeadersOrPaths() throws {
        let evil = "a.pdf\r\nBcc: x@evil.example\r\nContent-Type: text/html\0\u{202E}/../..\\\"x"
        let att = MailAttachment(filename: evil, contentType: "application/pdf", data: pdf(100))
        XCTAssertFalse(att.filename.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0.value == 0x202E })
        XCTAssertFalse(att.filename.contains("/")); XCTAssertFalse(att.filename.contains("\\")); XCTAssertFalse(att.filename.contains("\""))
        let wire = String(decoding: try message([att]).rfc822(), as: UTF8.self)
        let headerBlocks = wire.components(separatedBy: "\r\n\r\n")
        XCTAssertFalse(headerBlocks.joined().contains("\r\nBcc:"), "no injected header line")
        XCTAssertEqual(MailAttachment(filename: "\r\n\0", contentType: "application/pdf", data: Data()).filename, "anhang")
        XCTAssertLessThanOrEqual(MailAttachment(filename: String(repeating: "ä", count: 400), contentType: "application/pdf", data: Data()).filename.utf8.count, 255)
    }

    func testContentTypeIsAPlainTokenAndNeverActiveContent() {
        XCTAssertEqual(MailAttachment.safeContentType("Application/PDF"), "application/pdf")
        XCTAssertEqual(MailAttachment.safeContentType("image/heic"), "image/heic")
        for bad in ["text/html", "application/xhtml+xml", "image/svg+xml", "application/pdf\r\nX: y", "pdf", "multipart/mixed", "application/pdf; charset=x", ""] {
            XCTAssertEqual(MailAttachment.safeContentType(bad), "application/octet-stream", bad.debugDescription)
        }
    }

    func testWireSizeEstimateIsExactEnoughAndLimitEnforced() throws {
        let a = MailAttachment(filename: "x.pdf", contentType: "application/pdf", data: pdf(1_000_000))
        var m = try message([a]); m.maxWireBytes = 10_000_000
        let size = try m.rfc822().count
        XCTAssertLessThanOrEqual(size, a.wireBytes + 2_000)
        XCTAssertGreaterThan(size, a.wireBytes - 200)
        m.maxWireBytes = size - 1
        XCTAssertThrowsError(try m.rfc822()) { XCTAssertEqual($0 as? MailError, .tooLarge) }
    }

    func testFitIsGreedyInOrderAndNamesWhatDoesNotFit() {
        let big = MailAttachment(filename: "gross.pdf", contentType: "application/pdf", data: pdf(19_900_000))
        let mid = MailAttachment(filename: "mittel.pdf", contentType: "application/pdf", data: pdf(5_000_000))
        let small = MailAttachment(filename: "klein.pdf", contentType: "application/pdf", data: pdf(10_000))
        let fit = MailAttachmentFit([big, mid, small], baseBytes: 10_000, limit: MailMessage.defaultMaxWireBytes, maxCount: 5)
        XCTAssertEqual(fit.attached.map(\.filename), ["gross.pdf", "klein.pdf"])
        XCTAssertEqual(fit.omitted.map(\.filename), ["mittel.pdf"])
        // 19.9 MB alone must go (the limit of the migration requirement)
        XCTAssertEqual(MailAttachmentFit([big], baseBytes: 10_000, limit: MailMessage.defaultMaxWireBytes, maxCount: 5).omitted.count, 0)
        // proxy: one attachment
        XCTAssertEqual(MailAttachmentFit([small, small], baseBytes: 0, limit: 1 << 30, maxCount: 1).omitted.count, 1)
    }

    func testNoticeNamesOmittedFilesPlainAndHTMLEscaped() {
        let x = MailAttachment(filename: "<b>x<i>.pdf", contentType: "application/pdf", data: Data(count: 2_500_000))
        let plain = MailAttachmentNotice.render(omitted: [x], unavailable: 0, limit: 30 << 20, html: false)
        XCTAssertTrue(plain.contains("- <b>x<i>.pdf (2,4 MB)")); XCTAssertTrue(plain.contains("30,0 MB"))
        let html = MailAttachmentNotice.render(omitted: [x], unavailable: 1, limit: 30 << 20, html: true)
        XCTAssertTrue(html.contains("&lt;b&gt;x&lt;i&gt;.pdf")); XCTAssertFalse(html.contains("<b>x"))
        XCTAssertTrue(html.contains("nicht beigefügt"))
    }

    func testDotStuffingOfBytesMatchesTheStringForm() {
        let wire = Data("a\r\n.b\r\n..c\r\n".utf8)
        XCTAssertEqual(String(decoding: SMTPTransport.dotStuffedData(wire), as: UTF8.self), "a\r\n..b\r\n...c\r\n.\r\n")
        XCTAssertEqual(String(decoding: SMTPTransport.dotStuffedData(Data(".".utf8)), as: UTF8.self), "..\r\n.\r\n")
    }

    func testProxyBase64IsFormEncodedAndRoundTrips() throws {
        let raw = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7) }) + Data([0xFB, 0xFF, 0xBF])
        let enc = String(decoding: MailProxyTransport.percentEncodedBase64(raw), as: UTF8.self)
        XCTAssertFalse(enc.contains("+")); XCTAssertFalse(enc.contains("/")); XCTAssertFalse(enc.contains("="))
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(enc.removingPercentEncoding)), raw)
    }
}
