// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FormMail

/// Interop with a REAL mail server and an independent MIME parser (Mailpit). Needs P4A_MAILPIT_SMTP_PORT / P4A_MAILPIT_API_PORT
/// (and optionally P4A_MAILPIT_HOST); started by backend/mail-interop.sh and backend/ci-linux.sh, otherwise skipped.
/// Mailpit serves STARTTLS with the synthetic test certificate and accepts any AUTH credentials over TLS.
final class MailpitInteropTests: XCTestCase {
    private var env: (host: String, smtp: Int, api: Int)!
    private let nets = ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"].compactMap { CIDR($0) }

    override func setUpWithError() throws {
        let e = ProcessInfo.processInfo.environment
        guard let s = e["P4A_MAILPIT_SMTP_PORT"].flatMap(Int.init), let a = e["P4A_MAILPIT_API_PORT"].flatMap(Int.init) else { throw XCTSkip("Mailpit not available; run backend/mail-interop.sh") }
        env = (e["P4A_MAILPIT_HOST"] ?? "127.0.0.1", s, a)
    }

    private func api(_ path: String, method: String = "GET") async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "http://\(env.host):\(env.api)\(path)")!); r.httpMethod = method
        let (d, _) = try await URLSession.shared.data(for: r)
        return (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }
    private func clear() async throws { _ = try await api("/api/v1/messages", method: "DELETE") }
    private func newest() async throws -> [String: Any] {
        for _ in 0..<60 {
            if let first = ((try await api("/api/v1/messages"))["messages"] as? [[String: Any]])?.first, let id = first["ID"] as? String { return try await api("/api/v1/message/\(id)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("no message arrived"); return [:]
    }
    private func transport(_ security: SMTPConfig.Security, user: String? = nil, pass: String? = nil) -> SMTPTransport {
        SMTPTransport(config: SMTPConfig(host: env.host, port: env.smtp, security: security, username: user, password: pass, verifyCertificate: false), allowedNets: nets, allowInsecure: security == .plain)
    }
    private func message(html: Bool) throws -> MailMessage {
        try MailMessage(fromAddress: "praxis@example.org", fromName: "Praxis Müller & Söhne", to: ["empfang@example.org"], bcc: ["archiv@example.org"], replyTo: "erika@example.net",
                        subject: "Neue Anfrage: Grüße 🌍 " + String(repeating: "Überlang ", count: 12),
                        body: html ? "<p>Grüße &amp; Hallo</p>\n<p>.Punkt am Anfang</p>" : "Zeile 1 ü\n.Zeile mit Punkt\r\nZeile 3", isHTML: html)
    }
    private func addresses(_ any: Any?) -> [String] { (any as? [[String: Any]])?.compactMap { $0["Address"] as? String } ?? [] }

    func testPlainTextMessageIsParsedCorrectlyByARealServer() async throws {
        try await clear()
        try await transport(.plain).send(try message(html: false))
        let m = try await newest()
        XCTAssertEqual(m["Subject"] as? String, "Neue Anfrage: Grüße 🌍 " + String(repeating: "Überlang ", count: 12).trimmingCharacters(in: .whitespaces) + (String(repeating: "Überlang ", count: 12).hasSuffix(" ") ? " " : ""))
        XCTAssertEqual(addresses(m["To"]), ["empfang@example.org"]); XCTAssertEqual(addresses(m["Bcc"]), ["archiv@example.org"])
        XCTAssertEqual(addresses(m["ReplyTo"]), ["erika@example.net"])
        XCTAssertEqual((m["From"] as? [String: Any])?["Address"] as? String, "praxis@example.org"); XCTAssertEqual((m["From"] as? [String: Any])?["Name"] as? String, "Praxis Müller & Söhne")
        XCTAssertEqual((m["Text"] as? String)?.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines), "Zeile 1 ü\n.Zeile mit Punkt\nZeile 3", "dot-stuffing is undone, UTF-8 intact")
        XCTAssertTrue((m["HTML"] as? String ?? "").isEmpty)
    }

    func testHTMLMessageOverSTARTTLSWithAuthentication() async throws {
        try await clear()
        try await transport(.starttls, user: "anyone", pass: "anything").send(try message(html: true))
        let m = try await newest()
        XCTAssertTrue((m["HTML"] as? String ?? "").contains("<p>Grüße &amp; Hallo</p>")); XCTAssertTrue((m["HTML"] as? String ?? "").contains(".Punkt am Anfang"))
        XCTAssertEqual(addresses(m["To"]), ["empfang@example.org"])
    }

    func testVerifyAgainstTheRealServerAndCertificateCheck() async throws {
        try await transport(.starttls, user: "anyone", pass: "anything").verify()
        // the server's certificate is self-signed: with verification on the connection must be refused
        let strict = SMTPTransport(config: SMTPConfig(host: env.host, port: env.smtp, security: .starttls, verifyCertificate: true), allowedNets: nets)
        do { try await strict.verify(); XCTFail("self-signed certificate accepted") } catch let e as MailTransportError { XCTAssertEqual(e.code, "tls_failed") }
    }
}
