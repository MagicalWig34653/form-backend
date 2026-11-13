// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormCore
import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import TestSupport
import XCTest
import XCTVapor

/// A certificate problem of the legacy source names its cause (host name, unknown CA, expired) instead of "could not be checked".
/// The fake server below speaks the MariaDB greeting, offers TLS and presents a synthetic certificate (TestSupport/Fixtures); it counts
/// what the client sends in plain text (only the 36-byte SSLRequest is allowed) and after TLS (nothing: no credentials ever).
/// Needs P4A_DB_PORT/P4A_DB_PASSWORD like ImportRehearsalTests (backend/integration-test.sh).
final class SourceCertificateTests: XCTestCase {
    // MARK: classify (pure)

    func testClassifyNamesCertificateCauses() {
        XCTAssertEqual(SourceFailure.classify(NIOSSLExtraError.failedToValidateHostname), .certHostname)
        XCTAssertEqual(SourceFailure.classify(NIOSSLError.unableToValidateCertificate), .certUntrusted)
        XCTAssertEqual(SourceFailure.certHostname.jobCode, "source_cert_hostname")
        XCTAssertEqual(SourceFailure.certUntrusted.jobCode, "source_cert_untrusted")
        XCTAssertEqual(SourceFailure.certExpired.jobCode, "source_cert_expired")
        for failure in [SourceFailure.certHostname, .certUntrusted, .certExpired] {
            XCTAssertLessThanOrEqual(failure.jobCode.count, 40, "job error column is VARCHAR(40)")
            XCTAssertTrue(failure.message.contains("Zertifikat"), failure.message)
            XCTAssertEqual(MigrationService.errorCode(for: failure), failure.jobCode)
        }
        // Unrelated errors keep their cause.
        XCTAssertEqual(SourceFailure.classify(MySQLError.closed), .unreachable)
        XCTAssertEqual(SourceFailure.classify(NIOSSLError.uncleanShutdown), .generic)
    }

    // MARK: through the real route, against a TLS server with a certificate the system does not trust

    func testUntrustedCertificateIsNamedAndNoCredentialIsSent() async throws {
        let fake = try await FakeTLSMySQL(certificate: "test-cert.pem")
        let (status, text) = try await check(fake)
        XCTAssertEqual(status, .unprocessableEntity, text)
        XCTAssertTrue(text.contains("unbekannten Stelle"), text)
        XCTAssertEqual(fake.tlsConnections, 2, "real connection plus the diagnosis connection")
        await fake.assertNoCredentials()
        await fake.stop()
    }

    func testExpiredCertificateIsNamedByTheDiagnosis() async throws {
        let fake = try await FakeTLSMySQL(certificate: "test-cert-expired.pem")
        let (status, text) = try await check(fake)
        XCTAssertEqual(status, .unprocessableEntity, text)
        XCTAssertTrue(text.contains("abgelaufen"), text)
        XCTAssertEqual(fake.tlsConnections, 2)
        await fake.assertNoCredentials()
        await fake.stop()
    }

    func testFailedDiagnosisStaysUntrusted() async throws {
        let fake = try await FakeTLSMySQL(certificate: "test-cert-expired.pem", refuseTLSFrom: 2)  // the diagnosis (second TLS attempt) gets cut
        let (status, text) = try await check(fake)
        XCTAssertEqual(status, .unprocessableEntity, text)
        XCTAssertTrue(text.contains("unbekannten Stelle"), text)
        await fake.assertNoCredentials()
        await fake.stop()
    }

    private func check(_ fake: FakeTLSMySQL) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.ok, "")
        try await ImportRehearsalTests().withHarness(perForm: 1, statistics: 0) { h in
            var body = h.sourceBody(user: "srcuser-geheim", password: "pw-geheim", database: "alt", port: fake.port, host: "127.0.0.1")
            body["tls"] = "verify"
            let (status, _, text) = try await h.test(body)
            try await Task.sleep(nanoseconds: 300_000_000)
            for secret in ["pw-geheim", "srcuser-geheim", "127.0.0.1"] { XCTAssertFalse(text.contains(secret), "echoes \(secret)") }
            result = (status, text)
        }
        return result
    }
}

/// MariaDB-like server with TLS: greeting offers CLIENT_SSL, after the 36-byte SSLRequest the TLS handshake follows. Never answers a login.
final class FakeTLSMySQL: @unchecked Sendable {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var channel: Channel!
    private let lock = NSLock()
    private var plainBytes: [Int] = []  // per TLS attempt: bytes before TLS (SSLRequest only)
    private var appBytes = 0            // bytes after TLS (what a login would be)
    private var attempts = 0
    var port: Int { channel.localAddress!.port! }
    var tlsConnections: Int { lock.lock(); defer { lock.unlock() }; return attempts }

    init(certificate: String, refuseTLSFrom: Int = .max) async throws {
        let tls = try FakeSMTPServer.tlsContext(certificate: certificate)
        let box = Box()
        channel = try await ServerBootstrap(group: group).childChannelInitializer { ch in
            ch.pipeline.addHandler(Session(server: box.owner!, tls: tls, refuseTLSFrom: refuseTLSFrom))
        }.bind(host: "127.0.0.1", port: 0).get()
        box.owner = self
    }
    private final class Box: @unchecked Sendable { var owner: FakeTLSMySQL? }
    func stop() async { try? await channel.close().get(); try? await group.shutdownGracefully() }
    fileprivate func begin() -> Int { lock.lock(); defer { lock.unlock() }; attempts += 1; plainBytes.append(0); return attempts }
    fileprivate func plain(_ attempt: Int, _ n: Int) { lock.lock(); plainBytes[attempt - 1] += n; lock.unlock() }
    fileprivate func app(_ n: Int) { lock.lock(); appBytes += n; lock.unlock() }
    /// Neither the real attempt nor the diagnosis may send more than the SSLRequest or anything after TLS was established.
    func assertNoCredentials(file: StaticString = #filePath, line: UInt = #line) async {
        try? await Task.sleep(nanoseconds: 200_000_000)
        lock.lock(); let app = appBytes, plain = plainBytes; lock.unlock()
        XCTAssertEqual(app, 0, "bytes after the TLS handshake (credentials would travel here)", file: file, line: line)
        for n in plain { XCTAssertLessThanOrEqual(n, 36, "more than the SSLRequest was sent in plain text", file: file, line: line) }
    }

    final class Session: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let server: FakeTLSMySQL, tls: NIOSSLContext, refuseTLSFrom: Int
        var attempt = 0, plain = 0, tlsOn = false
        init(server: FakeTLSMySQL, tls: NIOSSLContext, refuseTLSFrom: Int) { self.server = server; self.tls = tls; self.refuseTLSFrom = refuseTLSFrom }
        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(bytes: ImportRehearsalTests.greeting(ssl: true))), promise: nil)
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            if tlsOn { server.app(buffer.readableBytes); return }
            if attempt == 0 { attempt = server.begin() }
            let take = min(buffer.readableBytes, 36 - plain)
            plain += take; server.plain(attempt, take)
            buffer.moveReaderIndex(forwardBy: take)
            guard plain == 36 else { return }
            if attempt >= refuseTLSFrom { context.close(promise: nil); return }
            tlsOn = true
            do { try context.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls), position: .first) } catch { context.close(promise: nil); return }
            if buffer.readableBytes > 0 { context.pipeline.fireChannelRead(NIOAny(buffer)) }
        }
    }
}
