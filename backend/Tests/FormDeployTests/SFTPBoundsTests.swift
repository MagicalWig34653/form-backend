// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import TestSupport
import XCTest
@testable import FormDeploy

/// Review Astra 2 M6 against the in-process SFTP server (no Docker): no endless loops on empty answers, absolute session deadline.
final class SFTPBoundsTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!]

    func testEmptyDataPacketsAreNoProgressAndTheDeadlineHolds() async throws {
        let s = FakeSFTPServer(); try await s.start()
        do {
            s.seed("/objects/a.bin", data: Data("payload".utf8))
            let c = SFTPClient(config: SFTPConfig(host: "127.0.0.1", port: s.port, username: s.user, password: s.password, hostKeySHA256: s.fingerprint, timeout: 5), allowedNets: loopback)
            try await c.connect()
            let back = try await c.download("/objects/a.bin", limit: 1 << 20)
            XCTAssertEqual(back, Data("payload".utf8))
            s.emptyReads = true
            do { _ = try await c.download("/objects/a.bin", limit: 1 << 20); XCTFail("expected no_progress") } catch let e as FTPError { XCTAssertEqual(e.code, "no_progress") }
            await c.close()

            s.emptyReads = false
            let slow = SFTPClient(config: SFTPConfig(host: "127.0.0.1", port: s.port, username: s.user, password: s.password, hostKeySHA256: s.fingerprint, timeout: 5, totalTimeout: 1.5), allowedNets: loopback)
            try await slow.connect()
            try await Task.sleep(nanoseconds: 1_700_000_000)
            do { _ = try await slow.download("/objects/a.bin", limit: 1 << 20); XCTFail("expected deadline_exceeded") } catch let e as FTPError { XCTAssertEqual(e.code, "deadline_exceeded") }
            await slow.close()
        } catch { await s.stop(); throw error }
        await s.stop()
    }

    /// Codex 1: a write that never completes (server stops reading) ends at the step timeout, not never.
    func testSendIsBoundedWhenTheServerStopsReading() async throws {
        let s = FakeSFTPServer(); try await s.start()
        do {
            let c = SFTPClient(config: SFTPConfig(host: "127.0.0.1", port: s.port, username: s.user, password: s.password, hostKeySHA256: s.fingerprint, timeout: 5, totalTimeout: 30), allowedNets: loopback)
            try await c.connect()
            c.timeoutForTests = 1
            s.stallInput = true
            _ = await c.exists("/objects")   // the last packet the server reads
            let started = Date()
            do { try await c.send(Data(count: 16 << 20)); XCTFail("expected timeout") } catch let e as FTPError { XCTAssertEqual(e.code, "timeout") }
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
            await c.close()
        } catch { await s.stop(); throw error }
        await s.stop()
    }
}
