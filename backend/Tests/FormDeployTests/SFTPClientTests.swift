// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import XCTest
@testable import FormDeploy

/// Against a REAL OpenSSH server (backend/sftp-test.sh starts one in Docker and sets the SFTP_TEST_* variables); skipped otherwise.
final class SFTPClientTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!]
    private func env() throws -> (port: Int, user: String, pass: String, base: String) {
        let e = ProcessInfo.processInfo.environment
        guard let p = e["SFTP_TEST_PORT"].flatMap(Int.init), let u = e["SFTP_TEST_USER"], let pw = e["SFTP_TEST_PASSWORD"], let b = e["SFTP_TEST_BASE"] else { throw XCTSkip("no SFTP server; run backend/sftp-test.sh") }
        return (p, u, pw, b)
    }
    private func client(_ x: (port: Int, user: String, pass: String, base: String), fingerprint: String, password: String? = nil) -> SFTPClient {
        SFTPClient(config: SFTPConfig(host: "127.0.0.1", port: x.port, username: x.user, password: password ?? x.pass, hostKeySHA256: fingerprint, timeout: 10), allowedNets: loopback)
    }
    private func expect(_ code: String, _ f: () async throws -> Void, line: UInt = #line) async {
        do { try await f(); XCTFail("expected \(code)", line: line) } catch let e as FTPError { XCTAssertEqual(e.code, code, line: line) } catch { XCTFail("\(error)", line: line) }
    }

    func testPinnedHostKeyAuthenticationAndFileOperations() async throws {
        let x = try env()
        var t0 = Date(); func lap(_ s: String) { print("LAP \(s) \(Int(Date().timeIntervalSince(t0)))s"); t0 = Date() }
        let fp = try await SFTPClient.probe(host: "127.0.0.1", port: x.port, allowedNets: loopback); lap("probe")
        XCTAssertTrue(SSHHostKey.isValid(fp), fp)
        if let known = ProcessInfo.processInfo.environment["SFTP_TEST_FINGERPRINT"] { XCTAssertEqual(fp, known, "same value ssh-keygen -l prints") }

        // the pin protects: wrong fingerprint, wrong password, blocked target
        await expect("host_key_mismatch") { try await client(x, fingerprint: "SHA256:" + String(repeating: "A", count: 43)).connect() }
        lap("mismatch")
        await expect("auth_failed") { try await client(x, fingerprint: fp, password: "wrong").connect() }
        lap("authfail")
        await expect("target_blocked") { try await SFTPClient(config: SFTPConfig(host: "127.0.0.1", port: x.port, username: x.user, password: x.pass, hostKeySHA256: fp), allowedNets: []).connect() }
        await expect("host_key_missing") { try await client(x, fingerprint: "nothing").connect() }

        lap("blocked+missing")
        let c = client(x, fingerprint: fp)
        try await c.connect(); lap("connect")
        let dir = x.base + "/t-" + UUID().uuidString.prefix(8)
        try await c.makeDirectory(dir)
        try await c.makeDirectory(dir)   // exists: tolerated
        let big = Data((0..<100_000).map { UInt8($0 % 251) })   // several 32 KiB chunks
        try await c.upload(dir + "/a.bin", big)
        let back = try await c.download(dir + "/a.bin", limit: 1 << 20)
        XCTAssertEqual(back, big)
        await expect("too_large") { _ = try await c.download(dir + "/a.bin", limit: 10) }
        try await c.rename(dir + "/a.bin", dir + "/b.bin")
        let ex1 = await c.exists(dir + "/b.bin"), ex2 = await c.exists(dir + "/a.bin"), isDir = await c.isDirectory(dir), isFile = await c.isDirectory(dir + "/b.bin")
        XCTAssertTrue(ex1); XCTAssertFalse(ex2); XCTAssertTrue(isDir); XCTAssertFalse(isFile)
        let names = try await c.list(dir)
        XCTAssertEqual(names, ["b.bin"])
        // rename onto an existing name is refused (no silent overwrite)
        try await c.upload(dir + "/c.bin", Data("c".utf8))
        await expect("sftp_4_rename") { try await c.rename(dir + "/c.bin", dir + "/b.bin") }
        try await c.delete(dir + "/b.bin"); try await c.delete(dir + "/c.bin")
        try await c.removeDirectory(dir)
        let gone = await c.exists(dir)
        XCTAssertFalse(gone)
        await c.close()
    }

    func testSDKInstallUpdateRollbackOverRealSFTP() async throws {
        let x = try env()
        let fp = try await SFTPClient.probe(host: "127.0.0.1", port: x.port, allowedNets: loopback)
        let c = client(x, fingerprint: fp)
        try await c.connect()
        let d = SDKDeployer(client: c)
        let dir = x.base + "/sdk-" + UUID().uuidString.prefix(8)
        func bundle(_ v: String) -> SDKBundle {
            SDKBundle(version: v, items: [.init(path: "VERSION", data: Data("\(v)\n".utf8)), .init(path: "src/Client.php", data: Data("<?php // \(v)\n".utf8)), .init(path: "bin/submit.php", data: Data("<?php\n".utf8))])
        }
        let r1 = try await d.install(bundle("0.2.0"), to: dir)
        XCTAssertEqual(r1, .installed(version: "0.2.0", previous: nil))
        let r2 = try await d.install(bundle("0.3.0"), to: dir)
        XCTAssertEqual(r2, .installed(version: "0.3.0", previous: "0.2.0"))
        let now = await d.installedVersion(dir), prev = await d.previousVersion(dir)
        XCTAssertEqual(now, "0.3.0"); XCTAssertEqual(prev, "0.2.0")
        let rb = try await d.rollback(dir)
        XCTAssertEqual(rb, .rolledBack(to: "0.2.0"))
        let after = await d.installedVersion(dir)
        XCTAssertEqual(after, "0.2.0")
        do { _ = try await d.install(bundle("0.1.0"), to: dir); XCTFail() } catch let e as FTPError { XCTAssertEqual(e.code, "downgrade_refused") }
        // clean up
        for p in [dir, dir + ".prev"] { try? await d.removeTree(p) }
        let cleaned = await c.exists(dir)
        XCTAssertFalse(cleaned)
        await c.close()
    }
}
