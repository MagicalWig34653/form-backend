// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import TestSupport
import Foundation
import NIOSSL
import XCTest
@testable import FormMail

final class SMTPTransportTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!, CIDR("::1/128")!]

    private func msg(body: String = "Hallo Welt\n.Punkt am Zeilenanfang\n", to: [String] = ["a@example.org"], bcc: [String] = ["geheim@example.org"]) throws -> MailMessage {
        try MailMessage(fromAddress: "von@example.org", fromName: "Formular", to: to, bcc: bcc, subject: "Grüße", body: body, isHTML: false)
    }
    private func transport(_ s: FakeSMTPServer, _ security: SMTPConfig.Security = .plain, user: String? = nil, password: String? = nil, verify: Bool = true,
                           timeout: TimeInterval = 5, insecure: Bool = true, host: String = "127.0.0.1") -> SMTPTransport {
        SMTPTransport(config: SMTPConfig(host: host, port: s.port, security: security, username: user, password: password, verifyCertificate: verify, timeout: timeout), allowedNets: loopback, allowInsecure: insecure)
    }
    private func withServer(_ o: FakeSMTPServer.Options = .init(), _ body: (FakeSMTPServer) async throws -> Void) async throws {
        let s = FakeSMTPServer(o); try await s.start()
        do { try await body(s) } catch { await s.stop(); throw error }
        await s.stop()
    }
    private func expectError(_ code: String, transient: Bool? = nil, file: StaticString = #filePath, line: UInt = #line, _ f: () async throws -> Void) async {
        do { try await f(); XCTFail("expected \(code)", file: file, line: line) }
        catch let e as MailTransportError { XCTAssertEqual(e.code, code, file: file, line: line); if let t = transient { XCTAssertEqual(e.transient, t, file: file, line: line) } }
        catch { XCTFail("unexpected \(error)", file: file, line: line) }
    }

    func testDeliversToAllRecipientsWithDotStuffingAndNoBccHeader() async throws {
        try await withServer { s in
            try await transport(s).send(try msg())
            let m = try XCTUnwrap(s.mails.first)
            XCTAssertEqual(m.from, "von@example.org"); XCTAssertEqual(m.rcpts, ["a@example.org", "geheim@example.org"])
            XCTAssertFalse(m.data.lowercased().contains("bcc")); XCTAssertTrue(m.data.contains("Subject: =?UTF-8?B?"))
            let b64 = m.data.components(separatedBy: "\r\n\r\n")[1].replacingOccurrences(of: "\r\n", with: "")
            XCTAssertEqual(String(decoding: Data(base64Encoded: b64)!, as: UTF8.self), "Hallo Welt\r\n.Punkt am Zeilenanfang\r\n")
            XCTAssertEqual(s.commands.last, "QUIT")
        }
    }

    func testDotStuffingOfRawLines() {
        XCTAssertEqual(SMTPTransport.dotStuffed(Data("a\r\n.b\r\n..c\r\n".utf8)), "a\r\n..b\r\n...c\r\n.\r\n")
        XCTAssertEqual(SMTPTransport.dotStuffed(Data("no final newline".utf8)), "no final newline\r\n.\r\n")
        XCTAssertEqual(SMTPTransport.dotStuffed(Data(".".utf8)), "..\r\n.\r\n")
    }

    func testPlainTextIsRefusedUnlessExplicitlyAllowed() async throws {
        try await withServer { s in
            await expectError("insecure_not_allowed", transient: false) { try await transport(s, .plain, insecure: false).send(try msg()) }
            XCTAssertTrue(s.commands.isEmpty, "nothing was even sent")
        }
    }

    func testSTARTTLSWithSelfSignedCertificateNeedsVerificationOff() async throws {
        var o = FakeSMTPServer.Options(); o.startTLS = true
        try await withServer(o) { s in
            await expectError("tls_failed") { try await transport(s, .starttls, verify: true).send(try msg()) }
            XCTAssertTrue(s.mails.isEmpty)
            try await transport(s, .starttls, verify: false).send(try msg())
            XCTAssertEqual(s.mails.count, 1)
            XCTAssertEqual(s.commands.filter { $0.hasPrefix("EHLO") }.count >= 3, true, "EHLO is repeated after the upgrade (2 runs: 1+2 EHLOs)")
        }
    }

    func testPlaintextInjectedBehindTheSTARTTLSReplyAbortsTheSession() async throws {
        var o = FakeSMTPServer.Options(); o.startTLS = true; o.injectAfterStartTLS = "250 forged"
        try await withServer(o) { s in
            // without the barrier the forged "250" is consumed as the EHLO answer and the session runs on (observed: smtp_250_data)
            do { try await transport(s, .starttls, verify: false).send(try msg()); XCTFail("must not succeed") }
            catch let e as MailTransportError { XCTAssertTrue(["starttls_injection", "tls_failed"].contains(e.code), e.code) }
            XCTAssertTrue(s.mails.isEmpty, "a forged answer must never count as delivery")
        }
    }

    func testSMTPSImplicitTLS() async throws {
        var o = FakeSMTPServer.Options(); o.implicitTLS = true
        try await withServer(o) { s in
            await expectError("tls_failed") { try await transport(s, .tls, verify: true).send(try msg()) }
            await expectError("insecure_not_allowed") { try await transport(s, .tls, verify: false, insecure: false).send(try msg()) }   // production: refused
            try await transport(s, .tls, verify: false, insecure: true).send(try msg())
            XCTAssertEqual(s.mails.count, 1)
        }
    }

    func testSTARTTLSRequiredButNotOffered() async throws {
        try await withServer { s in await expectError("starttls_unsupported", transient: false) { try await transport(s, .starttls, verify: false).send(try msg()) } }
    }

    func testAuthPlainAndLoginAndFailures() async throws {
        var o = FakeSMTPServer.Options(); o.startTLS = true; o.authMechanisms = ["PLAIN"]
        try await withServer(o) { s in
            try await transport(s, .starttls, user: "user", password: "secret", verify: false).send(try msg())
            XCTAssertEqual(s.mails.count, 1)
            await expectError("auth_failed", transient: false) { try await transport(s, .starttls, user: "user", password: "wrong", verify: false).send(try msg()) }
            XCTAssertEqual(s.mails.count, 1, "no mail after a failed login")
        }
        o.authMechanisms = ["LOGIN"]
        try await withServer(o) { s in
            try await transport(s, .starttls, user: "user", password: "secret", verify: false).send(try msg())
            XCTAssertEqual(s.mails.count, 1)
            await expectError("auth_failed", transient: false) { try await transport(s, .starttls, user: "nope", password: "secret", verify: false).send(try msg()) }
        }
        o.authMechanisms = ["CRAM-MD5"]
        try await withServer(o) { s in await expectError("auth_unsupported", transient: false) { try await transport(s, .starttls, user: "user", password: "secret", verify: false).send(try msg()) } }
        // credentials are never sent over an unencrypted channel unless explicitly allowed for development
        o.startTLS = false; o.authMechanisms = ["PLAIN"]
        try await withServer(o) { s in
            await expectError("insecure_not_allowed") { try await transport(s, .plain, user: "user", password: "secret", insecure: false).send(try msg()) }
            XCTAssertFalse(s.commands.contains { $0.hasPrefix("AUTH") })
        }
    }

    func testRecipientRejectionAbortsBeforeData() async throws {
        var o = FakeSMTPServer.Options(); o.rejectRecipients = ["bad@example.org"]
        try await withServer(o) { s in
            await expectError("rcpt_rejected", transient: false) { try await transport(s).send(try msg(to: ["a@example.org", "bad@example.org"])) }
            XCTAssertTrue(s.mails.isEmpty); XCTAssertFalse(s.commands.contains("DATA"), "no partial delivery")
            XCTAssertTrue(s.commands.contains("RSET"))
        }
        o.rcptReplyCode = 451
        try await withServer(o) { s in await expectError("rcpt_rejected", transient: true) { try await transport(s).send(try msg(to: ["bad@example.org"])) } }
    }

    func testServerErrorsAreClassified() async throws {
        var o = FakeSMTPServer.Options(); o.dataReply = "554 rejected as spam"
        try await withServer(o) { s in await expectError("smtp_554_data_end", transient: false) { try await transport(s).send(try msg()) } }
        o.dataReply = "451 try later"
        try await withServer(o) { s in await expectError("smtp_451_data_end", transient: true) { try await transport(s).send(try msg()) } }
        o = FakeSMTPServer.Options(); o.greeting = "554 no service"
        try await withServer(o) { s in await expectError("smtp_554_greeting", transient: false) { try await transport(s).send(try msg()) } }
        o = FakeSMTPServer.Options(); o.greeting = "garbage"
        try await withServer(o) { s in await expectError("bad_reply") { try await transport(s).send(try msg()) } }
    }

    func testTimeoutAndDroppedConnectionAndNoListener() async throws {
        var o = FakeSMTPServer.Options(); o.greetingDelay = .seconds(5)
        try await withServer(o) { s in
            let t0 = Date()
            await expectError("timeout", transient: true) { try await transport(s, timeout: 0.5).send(try msg()) }
            XCTAssertLessThan(Date().timeIntervalSince(t0), 3)
        }
        o = FakeSMTPServer.Options(); o.dropAfterGreeting = true
        try await withServer(o) { s in await expectError("connection_closed", transient: true) { try await transport(s).send(try msg()) } }
        let dead = FakeSMTPServer(); try await dead.start(); let port = dead.port; await dead.stop()
        await expectError("connect_failed", transient: true) { try await SMTPTransport(config: SMTPConfig(host: "127.0.0.1", port: port, security: .plain, timeout: 2), allowedNets: self.loopback, allowInsecure: true).send(try self.msg()) }
    }

    func testVerifyConnectsAndAuthenticatesWithoutSending() async throws {
        var o = FakeSMTPServer.Options(); o.startTLS = true; o.authMechanisms = ["PLAIN"]
        try await withServer(o) { s in
            try await transport(s, .starttls, user: "user", password: "secret", verify: false).verify()
            XCTAssertTrue(s.mails.isEmpty); XCTAssertFalse(s.commands.contains { $0.hasPrefix("MAIL") })
            await expectError("auth_failed") { try await transport(s, .starttls, user: "user", password: "x", verify: false).verify() }
        }
    }

    func testTargetGuardBlocksLoopbackAndPrivateRangesByDefault() async throws {
        try await withServer { s in
            let blocked = SMTPTransport(config: SMTPConfig(host: "127.0.0.1", port: s.port, security: .plain), allowedNets: [], allowInsecure: true)
            await expectError("target_blocked", transient: false) { try await blocked.send(try self.msg()) }
            await expectError("target_blocked", transient: false) { try await SMTPTransport(config: SMTPConfig(host: "localhost", port: s.port, security: .plain), allowedNets: [], allowInsecure: true).send(try self.msg()) }
            XCTAssertTrue(s.commands.isEmpty, "the blocked target never saw a connection")
        }
        for ip in ["10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "127.1.2.3", "::1", "fd00::1", "fe80::1", "::ffff:10.0.0.1", "::ffff:169.254.169.254", "224.0.0.1", "64:ff9b::a00:1"] {
            XCTAssertFalse(HostGuard.isAllowed(IPAddr(ip)!, allowedNets: []), ip)
        }
        for ip in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "::ffff:8.8.8.8"] { XCTAssertTrue(HostGuard.isAllowed(IPAddr(ip)!, allowedNets: []), ip) }
        XCTAssertTrue(HostGuard.isAllowed(IPAddr("10.1.2.3")!, allowedNets: [CIDR("10.0.0.0/8")!]), "explicit allow list wins")
        do { _ = try await HostGuard.resolve(host: "bad host!", allowedNets: []); XCTFail() } catch { XCTAssertEqual(error as? HostGuard.Failure, .unresolvable) }
        do { _ = try await HostGuard.resolve(host: "this-name-does-not-exist.invalid", allowedNets: []); XCTFail() } catch { XCTAssertEqual(error as? HostGuard.Failure, .unresolvable) }
        let lit = try await HostGuard.resolve(host: "8.8.8.8", allowedNets: []); XCTAssertEqual(lit, ["8.8.8.8"])
    }

    // MARK: certificate verification switch and IP literals

    private func smtpJSON(verify: Bool?) -> [String: Any] {
        var j: [String: Any] = ["host": "smtp.example.org", "port": 587, "security": "starttls"]
        if let v = verify { j["verifyCertificate"] = v }
        return j
    }

    func testProductionRefusesVerifyCertificateOffOnCreateAndOnTransportBuild() throws {
        XCTAssertThrowsError(try MailConnection.smtpConfig(smtpJSON(verify: false), password: nil, allowInsecure: false)) { XCTAssertEqual($0 as? MailConnection.Invalid, .init(reason: "verifyCertificate off is not allowed")) }
        // A stored connection with `false` must not build a transport in production either.
        XCTAssertThrowsError(try MailConnection.transport(kind: "smtp", safeConfig: smtpJSON(verify: false), secret: nil, allowedNets: [], allowInsecure: false))
        // Default and explicit true stay fine; the development switch permits false.
        XCTAssertTrue(try MailConnection.smtpConfig(smtpJSON(verify: nil), password: nil, allowInsecure: false).verifyCertificate)
        XCTAssertTrue(try MailConnection.smtpConfig(smtpJSON(verify: true), password: nil, allowInsecure: false).verifyCertificate)
        XCTAssertFalse(try MailConnection.smtpConfig(smtpJSON(verify: false), password: nil, allowInsecure: true).verifyCertificate)
        XCTAssertNoThrow(try MailConnection.transport(kind: "smtp", safeConfig: smtpJSON(verify: false), secret: nil, allowedNets: [], allowInsecure: true))
    }

    func testTransportItselfRefusesUnverifiedTLSWithoutTheDevelopmentSwitch() async throws {
        var o = FakeSMTPServer.Options(); o.startTLS = true
        try await withServer(o) { s in
            await expectError("insecure_not_allowed", transient: false) { try await transport(s, .starttls, verify: false, insecure: false).send(try msg()) }
            XCTAssertTrue(s.mails.isEmpty)
            try await transport(s, .starttls, verify: false, insecure: true).send(try msg())   // test mode permits it
            XCTAssertEqual(s.mails.count, 1)
        }
    }

    private func trusting(_ s: FakeSMTPServer, certificate: String, host: String = "127.0.0.1") throws -> SMTPTransport {
        var t = transport(s, .tls, verify: true, insecure: false, host: host)
        t.trustRoots = [try FakeSMTPServer.fixtureCertificate(certificate)]
        return t
    }

    func testIPLiteralIsVerifiedAgainstTheCertificatesIPSAN() async throws {
        // Chain is trusted in all three cases; only the IP identity differs.
        var o = FakeSMTPServer.Options(); o.implicitTLS = true
        try await withServer(o) { s in
            try await trusting(s, certificate: "test-cert.pem").send(try msg())   // SAN IP:127.0.0.1 matches
            XCTAssertEqual(s.mails.count, 1)
        }
        for bad in ["test-cert-otherip.pem", "test-cert-noip.pem"] {   // wrong IP SAN / no IP SAN (CN=127.0.0.1 must not count)
            var b = FakeSMTPServer.Options(); b.implicitTLS = true; b.certificate = bad
            try await withServer(b) { s in
                await expectError("tls_failed", transient: true) { try await trusting(s, certificate: bad).send(try msg()) }
                XCTAssertTrue(s.mails.isEmpty, bad)
            }
        }
    }

    func testHostnameConnectionsAreVerifiedAgainstTheNameNotTheAddress() async throws {
        var o = FakeSMTPServer.Options(); o.implicitTLS = true
        try await withServer(o) { s in
            // The certificate is valid for 127.0.0.1 (SAN) but not for "localhost": with verification on, a name that does not match is refused.
            await expectError("tls_failed") { try await self.transport(s, .tls, verify: true, host: "localhost").send(try self.msg()) }
        }
    }
}
