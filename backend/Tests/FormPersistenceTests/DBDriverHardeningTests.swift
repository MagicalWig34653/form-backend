// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import Logging
import NIOCore
import NIOSSL
import SQLKit
import Vapor
import XCTest
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// S2-04b/c and handshake-timeout regression tests against a real MariaDB (P4A_DB_PORT/P4A_DB_PASSWORD, backend/integration-test.sh).
/// The fault proxy is a plain TCP relay with a fault per connection. Synthetic data only.
final class DBDriverHardeningTests: XCTestCase {
    private func dbEnv() throws -> (host: String, port: Int, pw: String) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"].flatMap(Int.init), let pw = env["P4A_DB_PASSWORD"] else {
            throw XCTSkip("P4A_DB_PORT/P4A_DB_PASSWORD not set; run backend/integration-test.sh")
        }
        return (env["P4A_DB_HOST"] ?? "127.0.0.1", port, pw)
    }

    /// Plain-text configuration (TLS disabled, dev switch) so that the proxy can read the command packets.
    private func plainConfig(port: Int, pw: String) throws -> AppConfig {
        try AppConfig(env: ["FORM_DB_HOST": "127.0.0.1", "FORM_DB_PASSWORD": pw, "FORM_DB_PORT": "\(port)", "FORM_DB_USER": "root",
                            "FORM_DB_NAME": "p4atest", "FORM_DB_TLS": "disable", "FORM_ALLOW_INSECURE_DEV": "1"])
    }

    private func tlsTrust() -> TLSConfiguration {
        var t = TLSConfiguration.makeClientConfiguration(); t.certificateVerification = .none; return t
    }

    private func tlsConfig(_ db: (host: String, port: Int, pw: String)) throws -> AppConfig {
        try AppConfig(env: ["FORM_DB_HOST": db.host, "FORM_DB_PASSWORD": db.pw, "FORM_DB_PORT": "\(db.port)", "FORM_DB_USER": "root",
                            "FORM_DB_NAME": "p4atest", "FORM_DB_TLS": "verify"])
    }

    private func hex(_ s: String) -> String { s.utf8.map { String(format: "%02x", $0) }.joined() }

    // S2-04b: a session nested in a session (MigrationService.tick -> LegacyImporter.run) must not re-enable SQL logging.
    func testNestedSessionsDoNotLogSQLLiteralsOrBinds() async throws {
        let db = try dbEnv()
        for level in [Logger.Level.debug, .trace] {
            let sink = LogSink()
            let app = try await Application.make(.testing)
            var logger = Logger(label: "s204b", factory: { _ in sink })
            logger.logLevel = level
            app.logger = logger
            Persistence.configure(app, try tlsConfig(db), tlsConfiguration: tlsTrust())
            let secretLiteral = "SYNTHETICLITERAL" + String(UUID().uuidString.prefix(8))
            let secretBind = "SYNTHETICBIND" + String(UUID().uuidString.prefix(8))
            let literalHex = hex(secretLiteral)
            do {
                try await Persistence.sql(app).withSession { outer in
                    try await outer.withSession { inner in
                        try await inner.withSession { innermost in
                            try await innermost.raw("SELECT CONVERT(X'\(unsafeRaw: literalHex)' USING utf8mb4) AS v, \(bind: secretBind) AS b").run()
                        }
                    }
                }
            } catch { try? await app.asyncShutdown(); throw error }
            try await app.asyncShutdown()
            let text = sink.text
            XCTAssertFalse(text.isEmpty, "\(level): logger was exercised")
            XCTAssertFalse(text.contains("Executing query"), "\(level): nested session logged a statement")
            XCTAssertFalse(text.lowercased().contains(literalHex), "\(level): hex literal must not be logged")
            XCTAssertFalse(text.contains(secretBind), "\(level): bind value must not be logged")
        }
    }

    // S2-04c: connection abort after PREPARE leaves the statement open; the driver must not log (or assert with) the SQL text.
    func testAbortAfterPrepareDoesNotLogSQL() async throws {
        let db = try dbEnv()
        let proxy = try FaultProxy(upstreamHost: db.host, upstreamPort: db.port) { _ in .abortAfterPrepare }
        defer { proxy.stop() }
        let sink = LogSink()
        let app = try await Application.make(.testing)
        var logger = Logger(label: "s204c", factory: { _ in sink })
        logger.logLevel = .trace
        app.logger = logger
        Persistence.configure(app, try plainConfig(port: proxy.port, pw: db.pw))
        let secretLiteral = "SYNTHETICABORT" + String(UUID().uuidString.prefix(8))
        let literalHex = hex(secretLiteral)
        var failed = false
        do { try await Persistence.sql(app).raw("SELECT CONVERT(X'\(unsafeRaw: literalHex)' USING utf8mb4) AS v, '\(unsafeRaw: secretLiteral)' AS w").run() } catch { failed = true }
        // Give the loop a moment to release the aborted command.
        try await Task.sleep(nanoseconds: 300_000_000)
        try await app.asyncShutdown()
        XCTAssertTrue(failed, "the aborted query fails")
        XCTAssertTrue(proxy.preparesSeen > 0, "the abort happened after PREPARE")
        let text = sink.text
        XCTAssertFalse(text.contains(secretLiteral), "SQL literal in the log")
        XCTAssertFalse(text.lowercased().contains(literalHex), "hex literal in the log")
        XCTAssertFalse(text.contains("Statement not closed: SELECT"), "statement text in the log")
    }

    // Handshake: a server that accepts the TCP connection but never sends a greeting must end in an error after the
    // handshake timeout, and the pool (one connection per loop) must recover.
    func testSilentServerEndsInTimeoutAndPoolRecovers() async throws {
        try await poolRecovery(mode: .silent, timeout: 1, bound: 6, expectFast: false)
    }

    // The next three tests use a handshake timeout (30 s) far above the allowed failure latency (5 s): only the
    // channelInactive patch (connect promise fails when the peer closes) can explain a fast error, not the timer.
    // Peer closes before the greeting.
    func testCloseBeforeGreetingFailsFastAndPoolRecovers() async throws {
        try await poolRecovery(mode: .closeImmediately, timeout: 30, bound: 5, expectFast: true)
    }

    // Peer closes during authentication (greeting delivered, handshake response swallowed, then the socket is closed).
    func testCloseDuringAuthenticationFailsFastAndPoolRecovers() async throws {
        try await poolRecovery(mode: .greetingThenClose, timeout: 30, bound: 5, expectFast: true)
    }

    // Greeting arrives, then the server goes silent (stalled authentication): the timeout covers the later stages too.
    func testStalledAuthenticationEndsInTimeoutAndPoolRecovers() async throws {
        try await poolRecovery(mode: .greetingThenSilent, timeout: 1, bound: 6, expectFast: false)
    }

    // TLS stall: the server offers TLS, the client sends SSLRequest and ClientHello, the proxy swallows everything.
    // Only the handshake timeout can end this attempt (no inactive event, no error from the peer).
    func testStalledTLSHandshakeEndsInTimeoutAndPoolRecovers() async throws {
        try await poolRecovery(mode: .greetingThenSilent, timeout: 1, bound: 6, expectFast: false, tls: true)
    }

    private func poolRecovery(mode: FaultProxy.Mode, timeout: Int64, bound: Double, expectFast: Bool, tls: Bool = false) async throws {
        let db = try dbEnv()
        // Connection 0 is faulty, all following ones are relayed.
        let proxy = try FaultProxy(upstreamHost: db.host, upstreamPort: db.port) { $0 == 0 ? mode : .relay }
        defer { proxy.stop() }
        let app = try await Application.make(.testing)
        // One connection per event loop and every request on the same loop: a stuck attempt would block the whole pool.
        if tls {
            let cfg = try AppConfig(env: ["FORM_DB_HOST": "127.0.0.1", "FORM_DB_PASSWORD": db.pw, "FORM_DB_PORT": "\(proxy.port)", "FORM_DB_USER": "root",
                                         "FORM_DB_NAME": "p4atest", "FORM_DB_TLS": "verify"])
            Persistence.configure(app, cfg, maxConnectionsPerEventLoop: 1, tlsConfiguration: tlsTrust(), handshakeTimeout: .seconds(timeout))
        } else {
            Persistence.configure(app, try plainConfig(port: proxy.port, pw: db.pw), maxConnectionsPerEventLoop: 1, handshakeTimeout: .seconds(timeout))
        }
        let loop = app.eventLoopGroup.next()
        let sql = app.databases.database(.mysql, logger: app.logger, on: loop)! as! SQLDatabase

        let started = Date()
        let first = await watchdog(seconds: 12, onExpiry: { proxy.stop() }) { try await sql.raw("SELECT 1").run() }
        let firstTook = Date().timeIntervalSince(started)
        XCTAssertEqual(first, .failed, "the first query must fail with an error, not hang (took \(firstTook) s)")
        XCTAssertLessThan(firstTook, bound, "the failure must follow the handshake timeout (\(timeout) s), not the 10 s pool timeout")
        if !expectFast { XCTAssertGreaterThanOrEqual(firstTook, Double(timeout) * 0.8, "the timer ended the attempt") }

        // The same pool slot (maxConnectionsPerEventLoop 1, same loop) must be reusable.
        let second = await watchdog(seconds: 12, onExpiry: { proxy.stop() }) { try await sql.raw("SELECT 1").run() }
        XCTAssertEqual(second, .ok, "the pool must recover after the aborted handshake")
        XCTAssertGreaterThanOrEqual(proxy.connections, 2)
        _ = await watchdog(seconds: 10, onExpiry: {}) { try await app.asyncShutdown() }
    }

    // S2-04 / fb-sec vendor review 1: a failed login is logged by the connection pool (error level, independent of
    // sqlLogLevel). The server message (user, host, arbitrary text) must not reach any log at info or trace.
    func testAuthErrorPacketIsNotLogged() async throws {
        let db = try dbEnv()
        let userMarker = "SYNTHUSER" + String(UUID().uuidString.prefix(8))
        let hostMarker = "SYNTHHOST" + String(UUID().uuidString.prefix(8))
        let textMarker = "SYNTHTEXT" + String(UUID().uuidString.prefix(8))
        let message = "Access denied for user '\(userMarker)'@'\(hostMarker)' (using password: YES) \(textMarker)"
        for level in [Logger.Level.info, .trace] {
            let proxy = try FaultProxy(upstreamHost: db.host, upstreamPort: db.port) { _ in .forgedAuthError(message) }
            defer { proxy.stop() }
            let sink = LogSink()
            let app = try await Application.make(.testing)
            var logger = Logger(label: "authlog", factory: { _ in sink })
            logger.logLevel = level
            app.logger = logger
            Persistence.configure(app, try plainConfig(port: proxy.port, pw: db.pw), maxConnectionsPerEventLoop: 1, handshakeTimeout: .seconds(30))
            let sql = app.databases.database(.mysql, logger: logger, on: app.eventLoopGroup.next())! as! SQLDatabase
            let outcome = await watchdog(seconds: 12, onExpiry: { proxy.stop() }) { try await sql.raw("SELECT 1").run() }
            try? await Task.sleep(nanoseconds: 300_000_000)
            _ = await watchdog(seconds: 10, onExpiry: {}) { try await app.asyncShutdown() }
            XCTAssertEqual(outcome, .failed, "\(level): the forged ERR fails the connect")
            let text = sink.text
            XCTAssertFalse(text.isEmpty, "\(level): logger was exercised")
            var leaks: [String] = []
            for (name, marker) in [("user", userMarker), ("host", hostMarker), ("server text", textMarker)] where text.contains(marker) { leaks.append(name) }
            XCTAssertTrue(leaks.isEmpty, "\(level): \(leaks) from the auth ERR packet is in the log:\n\(text)")
            XCTAssertTrue(text.contains("1045"), "\(level): errno stays in the log for diagnosis")
        }
    }

    enum Outcome { case ok, failed, hung }

    /// Real watchdog: the result is delivered after `seconds` even if the operation never returns (a task group would wait
    /// for the child, and cancelling does not abort a NIO future). `onExpiry` forcibly closes the connections (proxy).
    private func watchdog(seconds: Double, onExpiry: @escaping @Sendable () -> Void, _ op: @escaping @Sendable () async throws -> Void) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            let once = OnceGate(cont)
            let task = Task { do { try await op(); once.resume(.ok) } catch { once.resume(.failed) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.resume(.hung) { onExpiry(); task.cancel() }
            }
        }
    }
}

private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<DBDriverHardeningTests.Outcome, Never>?
    init(_ c: CheckedContinuation<DBDriverHardeningTests.Outcome, Never>) { cont = c }
    @discardableResult func resume(_ o: DBDriverHardeningTests.Outcome) -> Bool {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        guard let c else { return false }
        c.resume(returning: o); return true
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { get { lock.lock(); defer { lock.unlock() }; return v } set { lock.lock(); v = newValue; lock.unlock() } }
}

/// Blocking TCP relay on 127.0.0.1:random with a fault per accepted connection (chosen by connection index).
private final class FaultProxy: @unchecked Sendable {
    enum Mode: Equatable { case relay, silent, closeImmediately, greetingThenSilent, greetingThenClose, abortAfterPrepare, forgedAuthError(String) }
    let port: Int
    private let listenFD: Int32
    private let upHost: String, upPort: Int
    private let modeFor: @Sendable (Int) -> Mode
    private let lock = NSLock()
    private var _connections = 0, _prepares = 0
    private var held: [Int32] = []
    var connections: Int { lock.lock(); defer { lock.unlock() }; return _connections }
    var preparesSeen: Int { lock.lock(); defer { lock.unlock() }; return _prepares }

    init(upstreamHost: String, upstreamPort: Int, mode: @escaping @Sendable (Int) -> Mode) throws {
        upHost = upstreamHost; upPort = upstreamPort; modeFor = mode
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

    func stop() {
        shutdown(listenFD, Int32(SHUT_RDWR)); close(listenFD)
        lock.lock(); let fds = held; held = []; lock.unlock()
        for fd in fds { shutdown(fd, Int32(SHUT_RDWR)); close(fd) }
    }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            lock.lock(); let index = _connections; _connections += 1; lock.unlock()
            let mode = modeFor(index)
            Thread.detachNewThread { [self] in handle(c, mode) }
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

    private func writeAll(_ fd: Int32, _ b: [UInt8]) {
        var off = 0
        while off < b.count {
            let w = b.withUnsafeBytes { write(fd, $0.baseAddress! + off, b.count - off) }
            if w <= 0 { return }
            off += w
        }
    }

    private func handle(_ client: Int32, _ mode: Mode) {
        switch mode {
        case .closeImmediately:
            close(client); return
        case .silent:
            lock.lock(); held.append(client); lock.unlock(); return   // never answers; closed by stop()
        default: break
        }
        guard let up = connectUpstream() else { close(client); return }
        let abortAfterPrepare = mode == .abortAfterPrepare
        var forgedMessage: String?
        if case .forgedAuthError(let m) = mode { forgedMessage = m }
        let stall = mode == .greetingThenSilent || mode == .greetingThenClose || forgedMessage != nil
        let sawPrepare = Flag()
        // server -> client
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 16384)
            var first = true
            while true {
                let r = buf.withUnsafeMutableBytes { read(up, $0.baseAddress!, 16384) }
                if r <= 0 { break }
                writeAll(client, Array(buf[0..<r]))
                if stall && first { return }   // forward only the greeting
                first = false
                if abortAfterPrepare && sawPrepare.value {
                    usleep(150_000)   // let the client decode PREPARE_OK and send EXECUTE
                    break
                }
            }
            shutdown(client, Int32(SHUT_RDWR)); shutdown(up, Int32(SHUT_RDWR))
        }
        // client -> server
        var buf = [UInt8](repeating: 0, count: 16384)
        while true {
            let r = buf.withUnsafeMutableBytes { read(client, $0.baseAddress!, 16384) }
            if r <= 0 { break }
            if mode == .greetingThenClose { break }   // close during authentication
            if let m = forgedMessage {
                // ERR_Packet: 0xFF, errno 1045 (LE), '#', SQLSTATE 28000, message; sequence id follows the client's packet.
                let body: [UInt8] = [0xFF, 0x15, 0x04] + Array("#28000".utf8) + Array(m.utf8)
                writeAll(client, [UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF), 0, buf[3] &+ 1] + body)
                continue
            }
            if stall { continue }   // swallow the handshake response
            // A command packet is `len(3) seq(1)=0 command(1)`; COM_STMT_PREPARE is 0x16.
            if r > 4, buf[3] == 0, buf[4] == 0x16 {
                sawPrepare.value = true
                lock.lock(); _prepares += 1; lock.unlock()
            }
            writeAll(up, Array(buf[0..<r]))
        }
        shutdown(up, Int32(SHUT_RDWR)); close(up); close(client)
    }
}
