// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import TestSupport
import XCTVapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import FormAuth

/// Card 01480C4B: a client that disconnects while its request waits in the body-budget queue is dropped (nothing reserved, body unread, handler
/// never runs). DB-free; REAL TCP listener and a real client socket (the in-memory tester has neither sockets nor connection ends).
final class BodyBudgetGateConnectionTests: XCTestCase {
    private let mib = 1 << 20

    private final class Counter: @unchecked Sendable {
        private let l = NSLock(); private var n = 0
        func bump() { l.lock(); n += 1; l.unlock() }
        var value: Int { l.lock(); defer { l.unlock() }; return n }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 8, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() { if Date() > end { XCTFail("timeout: \(what)"); return }; try await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// Running app with `POST /up` behind the gate; the handler counts runs and collects the body like the real routes.
    private func withServer(budget: BodyBudget, probe: (@Sendable (Request) -> Bool)? = nil, _ body: (Int, Counter) async throws -> Void) async throws {
        let app = try await Application.make(.testing, .singleton)
        let runs = Counter()
        app.bodyBudget = budget; app.connectionProbe = probe
        app.routes.grouped(BodyBudgetGate(maxBytes: 32 * mib)).on(.POST, "up", body: .collect(maxSize: "32mb")) { req async throws -> String in
            runs.bump(); return "\(req.body.data?.readableBytes ?? -1)"
        }
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        let port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
        app.listenerPorts = [port]
        do { try await body(port, runs) } catch { await app.server.shutdown(); try? await app.asyncShutdown(); throw error }
        await app.server.shutdown(); try await app.asyncShutdown()
    }

    private func request(bytes: Int) -> Data {
        var d = Data("POST /up HTTP/1.1\r\nHost: x\r\nContent-Type: application/octet-stream\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n".utf8)
        d.append(Data(repeating: 0x41, count: bytes)); return d
    }

    /// The client aborts (reset) while its request is queued: removed from the queue at once, nothing reserved, the body is never read.
    func testClientThatAbortsWhileQueuedIsRemovedFromTheQueueAndNothingIsReservedOrProcessed() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        try await withServer(budget: budget) { port, runs in
            let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))   // 60 of 64 MiB
            let client = try RawClient(port: port)
            let sent = client.send(request(bytes: 5 * mib))
            XCTAssertGreaterThan(sent, 5 * mib, "complete request accepted by the kernel")
            try await waitUntil("queued") { budget.waiting == 1 }
            client.reset()   // gives up
            try await waitUntil("removed from the queue") { budget.waiting == 0 }
            XCTAssertEqual(budget.cancelled, 1); XCTAssertEqual(budget.granted, 1, "never admitted"); XCTAssertEqual(budget.inFlight, 60 * mib)
            held.release()
            try await Task.sleep(nanoseconds: 700_000_000)
            XCTAssertEqual(budget.inFlight, 0); XCTAssertEqual(budget.granted, 1, "nothing was reserved for the abandoned request after the release")
            XCTAssertEqual(runs.value, 0, "the handler never ran: nothing stored, nothing mailed")
        }
    }

    /// The hard case (the one of the E2E): the client uploaded everything and closed normally; its FIN is still queued behind the unread data in
    /// the kernel, so nothing is visible while it waits. Once admitted, the gate reads the body, sees the closed connection and drops the request
    /// before the handler: never processed, lease returned.
    func testClientThatClosedAfterUploadingEverythingIsDroppedBeforeTheHandler() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        try await withServer(budget: budget) { port, runs in
            let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
            let client = try RawClient(port: port)
            XCTAssertGreaterThan(client.send(request(bytes: 5 * mib)), 5 * mib)
            try await waitUntil("queued") { budget.waiting == 1 }
            client.close()
            try await Task.sleep(nanoseconds: 700_000_000)
            held.release()
            try await waitUntil("admitted and returned") { budget.granted == 2 && budget.inFlight == 0 }
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(runs.value, 0, "the handler never ran: nothing stored, nothing mailed")
        }
    }

    /// Control: a client that stays is admitted after the release and processed (so the test above proves the cancel, not a broken route).
    func testClientThatStaysIsAdmittedAndProcessed() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        try await withServer(budget: budget) { port, runs in
            let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
            let client = try RawClient(port: port)
            client.send(request(bytes: 5 * mib))
            try await waitUntil("queued") { budget.waiting == 1 }
            try await Task.sleep(nanoseconds: 800_000_000)   // several polls with the client still connected
            XCTAssertEqual(budget.waiting, 1); XCTAssertEqual(budget.cancelled, 0)
            held.release()
            try await waitUntil("processed") { runs.value == 1 }
            client.close()
            try await waitUntil("lease returned") { budget.inFlight == 0 }
            XCTAssertEqual(budget.granted, 2)
        }
    }

    /// A client that leaves exactly when it is admitted (after the poll found it alive): the check after the reservation drops it before the body is read.
    func testClientGoneWhenAdmittedIsDroppedBeforeTheBodyIsRead() async throws {
        let budget = BodyBudget(capacity: 64 * mib, maxWait: 30)
        // open while queued (granted == 1: only the occupying lease), gone from the moment the request was admitted (granted == 2)
        try await withServer(budget: budget, probe: { _ in budget.granted < 2 }) { port, runs in
            let held = try XCTUnwrap(budget.reserve(bodyBytes: 20 * mib))
            let client = try RawClient(port: port)
            client.send(request(bytes: 5 * mib))
            try await waitUntil("queued") { budget.waiting == 1 }
            held.release()   // admits the queued request at once
            try await waitUntil("admitted and returned") { budget.granted == 2 && budget.inFlight == 0 }
            XCTAssertEqual(runs.value, 0, "the handler never ran")
            client.close()
        }
    }

    // MARK: ClientConnection / PeerSocket on a plain listening socket

    func testPeerSocketSeesEstablishedAndClosedConnections() throws {
        #if os(Linux)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        let listener = socket(AF_INET, type, 0)
        defer { _ = closeCompat(listener) }
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_addr.s_addr = inet_addr("127.0.0.1"); a.sin_port = 0
        XCTAssertEqual(withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sysBind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        XCTAssertEqual(listen(listener, 4), 0)
        var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let client = try RawClient(port: port)
        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        XCTAssertTrue(PeerSocket.isEstablished(peerIP: "127.0.0.1", peerPort: client.localPort, localPorts: [port]))
        XCTAssertFalse(PeerSocket.isEstablished(peerIP: "127.0.0.1", peerPort: client.localPort, localPorts: [port + 1]), "other local port: not this listener's connection")
        // unread data and a FIN: the connection is over although the data is still in the buffer
        client.send(Data(repeating: 1, count: 1000)); client.close()
        var open = true
        for _ in 0..<100 { open = PeerSocket.isEstablished(peerIP: "127.0.0.1", peerPort: client.localPort, localPorts: [port]); if !open { break }; usleep(20_000) }
        XCTAssertFalse(open, "FIN received, data still unread")
        _ = closeCompat(accepted)
        XCTAssertFalse(PeerSocket.isEstablished(peerIP: "127.0.0.1", peerPort: client.localPort, localPorts: [port]), "socket gone")
    }
}

private func closeCompat(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}

private func sysBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.bind(fd, a, len)
    #else
    return Glibc.bind(fd, a, len)
    #endif
}
