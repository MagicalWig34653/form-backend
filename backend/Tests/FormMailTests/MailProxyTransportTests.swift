// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import Vapor
import XCTest
@testable import FormMail

final class MailProxyTransportTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!]
    private final class Seen: @unchecked Sendable {
        let l = NSLock(); var requests: [(headers: HTTPHeaders, body: String)] = []
        func add(_ h: HTTPHeaders, _ b: String) { l.lock(); requests.append((h, b)); l.unlock() }
    }

    private func withProxy(status: HTTPStatus = .ok, testStatus: HTTPStatus = .accepted, redirectTo: String? = nil, _ body: (URL, Seen) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let seen = Seen()
        app.post("proxy") { req async throws -> Response in
            seen.add(req.headers, req.body.string ?? "")
            if let to = redirectTo { return req.redirect(to: to) }
            guard req.headers.first(name: "ACODE") == "right-code" else { return Response(status: .unauthorized, body: .init(string: "Unauthorized request")) }
            return Response(status: req.headers.first(name: "TEST") != nil ? testStatus : status, body: .init(string: "Success"))
        }
        app.get("secret") { _ in "must never be reached" }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = app.http.server.shared.localAddress!.port!
        defer { app.server.shutdown(); Task { try? await app.asyncShutdown() } }
        try await body(URL(string: "http://127.0.0.1:\(port)/proxy")!, seen)
    }

    private func msg(html: Bool = false) throws -> MailMessage {
        try MailMessage(fromAddress: "von@example.org", fromName: "Formular", to: ["a@example.org", "b@example.org"], bcc: ["geheim@example.org"], replyTo: "r@example.org",
                        subject: "Grüße <b>", body: html ? "<p>Hallo</p>" : "Zeile 1\nZeile <2>", isHTML: html)
    }
    private func transport(_ url: URL, code: String = "right-code") -> MailProxyTransport { MailProxyTransport(url: url, acode: code, allowedNets: loopback, allowInsecure: true) }
    private func form(_ body: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in body.components(separatedBy: "&") { let kv = pair.components(separatedBy: "="); if kv.count == 2 { out[kv[0]] = kv[1].removingPercentEncoding } }
        return out
    }
    private func decode(_ s: String?) -> String { String(decoding: Data(base64Encoded: s ?? "") ?? Data(), as: UTF8.self) }

    func testSendsTheLegacyProtocolFields() async throws {
        try await withProxy { url, seen in
            try await transport(url).send(try msg())
            let r = try XCTUnwrap(seen.requests.first)
            XCTAssertEqual(r.headers.first(name: "ACODE"), "right-code"); XCTAssertNil(r.headers.first(name: "TEST"))
            let f = form(r.body)
            XCTAssertEqual(Set(f.keys), ["mailTo", "mailBcc", "mailFrom", "mailBody", "mailSubject", "mailReplyTo", "mailAttachment", "mailAttachmentName"])
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decode(f["mailTo"]).utf8)) as? [String], ["a@example.org", "b@example.org"])
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decode(f["mailBcc"]).utf8)) as? [String], ["geheim@example.org"])
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(decode(f["mailFrom"]).utf8)) as? [String: String], ["address": "von@example.org", "name": "Formular"])
            XCTAssertEqual(decode(f["mailSubject"]), "Grüße <b>"); XCTAssertEqual(decode(f["mailReplyTo"]), "r@example.org")
            // the legacy proxy always renders HTML: plain text keeps its line breaks and is escaped
            XCTAssertEqual(decode(f["mailBody"]), "<pre style=\"font-family:inherit;white-space:pre-wrap\">Zeile 1\nZeile &lt;2&gt;</pre>")
            XCTAssertEqual(f["mailAttachment"], ""); XCTAssertEqual(f["mailAttachmentName"], "")
            try await transport(url).send(try msg(html: true))
            XCTAssertEqual(decode(form(seen.requests[1].body)["mailBody"]), "<p>Hallo</p>")
        }
    }

    func testStatusMappingAndAuth() async throws {
        try await withProxy { url, _ in
            do { try await transport(url, code: "wrong").send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_auth_failed"); XCTAssertFalse(e.transient) }
        }
        try await withProxy(status: .internalServerError) { url, _ in
            do { try await transport(url).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_500"); XCTAssertTrue(e.transient) }
        }
        try await withProxy(status: .preconditionFailed) { url, _ in
            do { try await transport(url).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_missing_parameters") }
        }
        try await withProxy(status: .created) { url, _ in   // only exactly 200 counts as sent
            do { try await transport(url).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_201") }
        }
    }

    func testVerifyUsesTheTestHeaderAndSendsNoMail() async throws {
        try await withProxy { url, seen in
            try await transport(url).verify()
            XCTAssertEqual(seen.requests.first?.headers.first(name: "TEST"), "1"); XCTAssertEqual(seen.requests.first?.body, "")
            do { try await transport(url, code: "wrong").verify(); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_auth_failed") }
        }
    }

    func testRedirectsAreNotFollowed() async throws {
        try await withProxy(redirectTo: "/secret") { url, seen in
            do { try await transport(url).send(try msg()); XCTFail("a redirect is not success") } catch let e as MailTransportError { XCTAssertTrue(e.code.hasPrefix("proxy_3"), e.code) }
            XCTAssertEqual(seen.requests.count, 1, "the redirect target was never requested")
        }
    }

    func testTargetAndURLRules() async throws {
        let u = URL(string: "http://127.0.0.1:9/proxy")!
        do { try await MailProxyTransport(url: u, acode: "x", allowedNets: [], allowInsecure: true).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "target_blocked") }
        do { try await MailProxyTransport(url: u, acode: "x", allowedNets: self.loopback, allowInsecure: false).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_url_invalid") }
        for bad in ["ftp://h.example/x", "https://u:p@h.example/x", "https://h.example/x#f", "https:///x", "file:///etc/passwd"] {
            XCTAssertThrowsError(try MailProxyTransport.validate(url: URL(string: bad)!, allowInsecure: true), bad)
        }
        XCTAssertNoThrow(try MailProxyTransport.validate(url: URL(string: "https://proxy.example.org/mail/")!, allowInsecure: false))
        let dead = URL(string: "http://127.0.0.1:1/proxy")!
        do { try await MailProxyTransport(url: dead, acode: "x", allowedNets: loopback, allowInsecure: true, timeout: .seconds(2)).send(try msg()); XCTFail() } catch let e as MailTransportError { XCTAssertEqual(e.code, "proxy_unreachable"); XCTAssertTrue(e.transient) }
    }

    func testConnectionConfigValidationAndFactory() throws {
        XCTAssertNoThrow(try MailConnection.smtpConfig(["host": "smtp.example.org", "port": 587, "security": "starttls", "username": "u"], password: "p", allowInsecure: false))
        for (bad, why) in [(["host": "h", "port": 25, "security": "plain"], "plain refused without allowInsecure"), (["host": "h", "port": 0, "security": "tls"], "port"),
                           (["host": "h h", "port": 25, "security": "tls"], "host"), (["host": "h", "port": 25, "security": "tls", "x": 1], "unknown member"),
                           (["host": "h", "port": 25, "security": "ssl"], "security"), (["host": "h", "port": 25, "security": "tls", "username": "u"], "user without password")] as [([String: Any], String)] {
            XCTAssertThrowsError(try MailConnection.smtpConfig(bad, password: nil, allowInsecure: false), why)
        }
        XCTAssertThrowsError(try MailConnection.smtpConfig(["host": "h", "port": 25, "security": "tls"], password: "p", allowInsecure: false), "password without user")
        XCTAssertThrowsError(try MailConnection.proxyURL(["url": "http://p.example/x"], allowInsecure: false))
        XCTAssertThrowsError(try MailConnection.transport(kind: "s3", safeConfig: [:], secret: nil, allowedNets: [], allowInsecure: false))
        XCTAssertThrowsError(try MailConnection.transport(kind: "mail-proxy", safeConfig: ["url": "https://p.example/x"], secret: nil, allowedNets: [], allowInsecure: false))
        XCTAssertTrue(try MailConnection.transport(kind: "smtp", safeConfig: ["host": "h.example", "port": 465, "security": "tls"], secret: nil, allowedNets: [], allowInsecure: false) is SMTPTransport)
    }
}
