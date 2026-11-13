// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor
import XCTVapor
import XCTest
@testable import FormIngest

/// Review Astra 2 M5: a per-replica budget of concurrent submissions BEFORE the body is collected; DB-free.
final class IngestGateTests: XCTestCase {
    private final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var _entered = 0
        var entered: Int { lock.lock(); defer { lock.unlock() }; return _entered }
        func wait() async { await withCheckedContinuation { c in lock.lock(); _entered += 1; waiting.append(c); lock.unlock() } }
        func releaseAll() { lock.lock(); let w = waiting; waiting = []; lock.unlock(); w.forEach { $0.resume() } }
    }
    private struct Blocking: AsyncResponder {
        let hold: Hold
        func respond(to request: Request) async throws -> Response { await hold.wait(); return Response(status: .ok) }
    }

    func testConcurrentSubmissionsBeyondTheBudgetAreRefusedBeforeTheBodyIsRead() async throws {
        let app = try await Application.make(.testing)
        do {
            let gate = IngestGate(maxConcurrent: 2)
            let hold = Hold()
            let responder = gate.makeResponder(chainingTo: Blocking(hold: hold))
            func call() async throws -> Response { try await responder.respond(to: Request(application: app, on: app.eventLoopGroup.next())).get() }
            let a = Task { try await call() }, b = Task { try await call() }
            for _ in 0..<200 where hold.entered < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(hold.entered, 2)
            // the third one is refused at once: 503 + Retry-After, never reaches the handler (or the body collection inside it)
            do { _ = try await call(); XCTFail("expected busy") }
            catch let e as IngestBusy { XCTAssertEqual(e.statusCode, 503); XCTAssertEqual(e.code, "ingest_busy"); XCTAssertEqual(e.extraHeaders.first?.name, "Retry-After") }
            XCTAssertEqual(hold.entered, 2)
            hold.releaseAll()
            _ = try await a.value; _ = try await b.value
            // slots are given back, also after errors
            let c = Task { try await call() }
            for _ in 0..<200 where hold.entered < 3 { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(hold.entered, 3)
            hold.releaseAll(); _ = try await c.value
            XCTAssertEqual(gate.inFlight, 0)
            let off = IngestGate(maxConcurrent: 0)   // 0 = no budget
            XCTAssertNil(off.acquire() ? nil : "refused")
        } catch { try await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}
