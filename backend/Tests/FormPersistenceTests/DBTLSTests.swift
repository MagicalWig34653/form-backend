// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import Logging
import NIOSSL
import SQLKit
import Vapor
import XCTest
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// S2-01 / S2-04 regression tests against a real MariaDB (P4A_DB_PORT/P4A_DB_PASSWORD, backend/integration-test.sh).
/// The proxy is a plain TCP relay that can strip CLIENT_SSL from the server greeting and counts every byte the
/// client sends. Synthetic credentials only.
final class DBTLSTests: XCTestCase {
    private func dbEnv() throws -> (host: String, port: Int, pw: String) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"].flatMap(Int.init), let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        return (env["P4A_DB_HOST"] ?? "127.0.0.1", port, pw)
    }

    private func config(host: String, port: Int, pw: String, tls: String = "verify") throws -> AppConfig {
        var e = ["FORM_DB_HOST": host, "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root",
                 "FORM_DB_NAME": "p4atest", "FORM_DB_TLS": tls]
        if tls == "disable" { e["FORM_ALLOW_INSECURE_DEV"] = "1" }
        return try AppConfig(env: e)
    }

    /// Accept-all trust for the container's self-signed certificate; the TLS handshake itself is still required.
    private func selfSignedTrust() -> TLSConfiguration {
        var t = TLSConfiguration.makeClientConfiguration()
        t.certificateVerification = .none
        return t
    }

    // (a) a server that offers no TLS at all: pool must fail, the client must not send a single byte (no auth packet).
    func testVerifyRefusesServerWithoutTLSBeforeAuthPacket() async throws {
        let db = try dbEnv()
        let proxy = try StrippingProxy(upstreamHost: db.host, upstreamPort: db.port, stripSSL: true)
        defer { proxy.stop() }
        let app = try await Application.make(.testing)
        Persistence.configure(app, try config(host: "127.0.0.1", port: proxy.port, pw: db.pw))
        var failed = false
        do { try await Persistence.sql(app).raw("SELECT 1").run() } catch { failed = true }
        try await app.asyncShutdown()
        XCTAssertTrue(failed, "verify must not connect to a server without CLIENT_SSL")
        XCTAssertGreaterThan(proxy.greetings, 0, "proxy was reached")
        XCTAssertTrue(proxy.sentNothingButQuit, "no SSLRequest or handshake response may be sent in plaintext (got \(proxy.clientBytes) bytes)")
    }

    // (b) CLIENT_SSL stripped from the greeting of a TLS-capable MariaDB (downgrade by a man in the middle).
    func testDowngradeByStrippingClientSSLIsRefused() async throws {
        let db = try dbEnv()
        let proxy = try StrippingProxy(upstreamHost: db.host, upstreamPort: db.port, stripSSL: true)
        defer { proxy.stop() }
        let app = try await Application.make(.testing)
        Persistence.configure(app, try config(host: "127.0.0.1", port: proxy.port, pw: db.pw), tlsConfiguration: selfSignedTrust())
        var failed = false
        do { try await Persistence.sql(app).raw("SELECT 1").run() } catch { failed = true }
        try await app.asyncShutdown()
        XCTAssertTrue(failed, "downgraded connection must be refused")
        XCTAssertTrue(proxy.sentNothingButQuit, "no authentication data may reach the wire (got \(proxy.clientBytes) bytes)")
        // Control: the same proxy without stripping works (proves the proxy/DB path is sound and the server offers TLS).
        let ok = try StrippingProxy(upstreamHost: db.host, upstreamPort: db.port, stripSSL: false)
        defer { ok.stop() }
        let app2 = try await Application.make(.testing)
        Persistence.configure(app2, try config(host: "127.0.0.1", port: ok.port, pw: db.pw), tlsConfiguration: selfSignedTrust())
        do { try await Persistence.sql(app2).raw("SELECT 1").run() } catch { try? await app2.asyncShutdown(); throw error }
        try await app2.asyncShutdown()
        XCTAssertGreaterThan(ok.clientBytes, 0)
    }

    // (c) positive: TLS-capable MariaDB with required TLS still works over an encrypted session, and the default
    // (system trust) verify refuses the untrusted self-signed certificate instead of falling back.
    func testVerifyWithTLSWorksAndUntrustedCertificateIsNotBypassed() async throws {
        let db = try dbEnv()
        let app = try await Application.make(.testing)
        Persistence.configure(app, try config(host: db.host, port: db.port, pw: db.pw), tlsConfiguration: selfSignedTrust())
        var cipher = ""
        do {
            let row = try await Persistence.sql(app).raw("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first()
            cipher = try row?.decode(column: "Value", as: String.self) ?? ""
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
        XCTAssertFalse(cipher.isEmpty, "session must be encrypted")

        let strict = try await Application.make(.testing)
        Persistence.configure(strict, try config(host: db.host, port: db.port, pw: db.pw))
        var failed = false
        do { try await Persistence.sql(strict).raw("SELECT 1").run() } catch { failed = true }
        try await strict.asyncShutdown()
        XCTAssertTrue(failed, "self-signed certificate must be rejected")
    }

    // S2-04: debug and trace must not leak bind values (hash) or packet payload bytes (password).
    func testDebugAndTraceLoggingDoNotLeakHashOrPasswordBytes() async throws {
        let db = try dbEnv()
        for level in [Logger.Level.debug, .trace] {
            let sink = LogSink()
            let app = try await Application.make(.testing)
            var logger = Logger(label: "s204", factory: { _ in sink })
            logger.logLevel = level
            app.logger = logger
            Persistence.configure(app, try config(host: db.host, port: db.port, pw: db.pw), tlsConfiguration: selfSignedTrust())
            let sql = Persistence.sql(app)
            let table = "s204_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10)
            let hash = "$argon2id$v=19$m=19456,t=2,p=1$SYNTHETICSALT" + String(UUID().uuidString.prefix(8)) + "$SYNTHETICHASHVALUE"
            do {
                try await sql.raw("CREATE TABLE \(ident: table) (h VARCHAR(255)) ENGINE=InnoDB").run()
                try await sql.raw("INSERT INTO \(ident: table) (h) VALUES (\(bind: hash))").run()
                try await sql.raw("UPDATE \(ident: table) SET h = \(bind: hash + "2") WHERE h = \(bind: hash)").run()
                try await sql.raw("DROP TABLE \(ident: table)").run()
            } catch { try? await sql.raw("DROP TABLE IF EXISTS \(ident: table)").run(); try? await app.asyncShutdown(); throw error }
            try await app.asyncShutdown()
            let text = sink.text
            XCTAssertFalse(text.isEmpty, "\(level): logger was exercised")
            XCTAssertFalse(text.contains("SYNTHETICHASHVALUE"), "\(level): hash must not be logged")
            let pwBytes = Array(db.pw.utf8.prefix(16)).map(String.init).joined(separator: ", ")
            XCTAssertFalse(text.contains(pwBytes), "\(level): password bytes must not be logged")
            XCTAssertFalse(text.contains(db.pw), "\(level): password must not be logged")
            XCTAssertFalse(text.contains("... (err: "), "\(level): no packet payload dump")
        }
    }
}

private final class LogSink: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace
    subscript(metadataKey k: String) -> Logger.Metadata.Value? { get { metadata[k] } set { metadata[k] = newValue } }
    func log(event: LogEvent) {
        lock.lock(); lines.append("\(event.message) \(event.metadata ?? [:])"); lock.unlock()
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}

/// Blocking TCP relay on 127.0.0.1:random. Rewrites the first server packet (HandshakeV10) when `stripSSL` is set.
private final class StrippingProxy: @unchecked Sendable {
    let port: Int
    private let listenFD: Int32
    private let upHost: String, upPort: Int, strip: Bool
    private let lock = NSLock()
    private var _clientBytes = 0, _greetings = 0, _sent: [UInt8] = []
    var clientBytes: Int { lock.lock(); defer { lock.unlock() }; return _clientBytes }
    /// True if the client sent nothing, or only a COM_QUIT packet (`01 00 00 <seq> 01`) when closing the refused connection.
    /// Any SSLRequest or handshake response (which carries user name and password scramble) would be longer.
    var sentNothingButQuit: Bool {
        lock.lock(); defer { lock.unlock() }
        return _sent.isEmpty || (_sent.count == 5 && Array(_sent[0..<3]) == [1, 0, 0] && _sent[4] == 1)
    }
    var greetings: Int { lock.lock(); defer { lock.unlock() }; return _greetings }

    init(upstreamHost: String, upstreamPort: Int, stripSSL: Bool) throws {
        upHost = upstreamHost; upPort = upstreamPort; strip = stripSSL
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0, listen(fd, 16) == 0 else { throw XCTSkip("cannot open proxy socket") }
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listenFD = fd; port = Int(UInt16(bigEndian: bound.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() { shutdown(listenFD, Int32(SHUT_RDWR)); close(listenFD) }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { [self] in relay(c) }
        }
    }

    private func connectUpstream() -> Int32? {
        var hints = addrinfo(); hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(upHost, String(upPort), &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(r.pointee.ai_family, r.pointee.ai_socktype, r.pointee.ai_protocol)
        guard connect(fd, r.pointee.ai_addr, r.pointee.ai_addrlen) == 0 else { close(fd); return nil }
        return fd
    }

    private func readExactly(_ fd: Int32, _ n: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: n); var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    private func writeAll(_ fd: Int32, _ b: [UInt8]) {
        var off = 0
        while off < b.count {
            let w = b.withUnsafeBytes { write(fd, $0.baseAddress! + off, b.count - off) }
            if w <= 0 { return }
            off += w
        }
    }

    private func relay(_ client: Int32) {
        guard let up = connectUpstream() else { close(client); return }
        // server -> client: strip CLIENT_SSL (0x0800 of the lower capability word) from the greeting.
        Thread.detachNewThread { [self] in
            if let hdr = readExactly(up, 4) {
                let n = Int(hdr[0]) | Int(hdr[1]) << 8 | Int(hdr[2]) << 16
                if var body = readExactly(up, n) {
                    lock.lock(); _greetings += 1; lock.unlock()
                    if strip, body.first == 10, let z = body.dropFirst().firstIndex(of: 0) {
                        let capIdx = z + 1 + 4 + 8 + 1
                        if capIdx + 1 < body.count { body[capIdx + 1] &= ~UInt8(0x08) }
                    }
                    writeAll(client, hdr + body)
                    var buf = [UInt8](repeating: 0, count: 16384)
                    while true {
                        let r = buf.withUnsafeMutableBytes { read(up, $0.baseAddress!, 16384) }
                        if r <= 0 { break }
                        writeAll(client, Array(buf[0..<r]))
                    }
                }
            }
            shutdown(client, Int32(SHUT_RDWR))
        }
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let r = buf.withUnsafeMutableBytes { read(client, $0.baseAddress!, 16384) }
            if r <= 0 { break }
            lock.lock(); _clientBytes += r; _sent += buf[0..<r]; lock.unlock()
            writeAll(up, Array(buf[0..<r]))
        }
        shutdown(up, Int32(SHUT_RDWR)); close(up); close(client)
    }
}
