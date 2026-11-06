// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import TestSupport
import XCTest
@testable import FormDeploy

final class FTPClientTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!]

    func client(_ s: FakeFTPServer, _ security: FTPConfig.Security, user: String = "ftpuser", password: String = "ftppass", verify: Bool = false, insecure: Bool? = nil) -> FTPClient {
        FTPClient(config: FTPConfig(host: "127.0.0.1", port: s.port, security: security, username: user, password: password, verifyCertificate: verify, timeout: 5), allowedNets: loopback, allowInsecure: insecure ?? (security != .plain))   // test servers use self-signed certificates
    }
    func withServer(_ o: FakeFTPServer.Options = .init(), _ body: (FakeFTPServer) async throws -> Void) async throws {
        let s = FakeFTPServer(o); try await s.start()
        do { try await body(s) } catch { await s.stop(); throw error }
        await s.stop()
    }
    func expectError(_ code: String, _ f: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await f(); XCTFail("expected \(code)", file: file, line: line) } catch let e as FTPError { XCTAssertEqual(e.code, code, file: file, line: line) } catch { XCTFail("\(error)", file: file, line: line) }
    }

    func testExplicitAndImplicitTLSUploadDownloadRenameDelete() async throws {
        for implicit in [false, true] {
            var o = FakeFTPServer.Options(); o.implicitTLS = implicit
            try await withServer(o) { s in
                let c = client(s, implicit ? .implicitTLS : .explicitTLS)
                try await c.connect()
                try await c.makeDirectory("/web")
                let payload = Data((0..<5000).map { UInt8($0 % 251) })
                try await c.upload("/web/a.bin", payload)
                XCTAssertEqual(s.files["/web/a.bin"], payload)
                let sz = try await c.size("/web/a.bin"), back = try await c.download("/web/a.bin")
                XCTAssertEqual(sz, 5000); XCTAssertEqual(back, payload)
                try await c.rename("/web/a.bin", "/web/b.bin")
                XCTAssertNil(s.files["/web/a.bin"]); XCTAssertNotNil(s.files["/web/b.bin"])
                let names = try await c.list("/web")
                XCTAssertEqual(names, ["b.bin"])
                let existsBefore = await c.exists("/web"), existsMissing = await c.exists("/nope")
                XCTAssertTrue(existsBefore); XCTAssertFalse(existsMissing)
                try await c.delete("/web/b.bin")
                try await c.removeDirectory("/web")
                XCTAssertFalse(s.dirs.contains("/web"))
                await c.close()
                XCTAssertFalse(s.log.contains { $0.contains("ftppass") }, "the password is never logged by the fake either")
            }
        }
    }

    func testWrongPasswordPlainRefusedAndForeignPasvAddressIgnored() async throws {
        try await withServer { s in
            await expectError("auth_failed") { try await client(s, .explicitTLS, password: "nope").connect() }
            await expectError("insecure_not_allowed") { try await client(s, .plain).connect() }
        }
        var o = FakeFTPServer.Options(); o.bogusPasvAddress = true; o.offerTLS = true
        try await withServer(o) { s in
            // EPSV is used first; PASV with a foreign address only matters if EPSV fails - the client connects to the control address either way
            let c = client(s, .explicitTLS)
            try await c.connect()
            try await c.upload("/x.bin", Data("ok".utf8))
            XCTAssertEqual(s.files["/x.bin"], Data("ok".utf8))
            await c.close()
        }
    }

    func testCertificateCheckCannotBeSwitchedOffInProduction() async throws {
        try await withServer { s in
            await expectError("insecure_not_allowed") { try await client(s, .explicitTLS, insecure: false).connect() }   // verify:false without the development release
        }
        XCTAssertThrowsError(try DeployService.ftpConfig(["host": "h", "username": "u", "verifyCertificate": false], password: "p", allowInsecure: false))
        XCTAssertNoThrow(try DeployService.ftpConfig(["host": "h", "username": "u", "verifyCertificate": false], password: "p", allowInsecure: true))
        XCTAssertNoThrow(try DeployService.ftpConfig(["host": "h", "username": "u"], password: "p", allowInsecure: false))
    }

    func testMalformedPassiveRepliesAreErrorsNotCrashes() async throws {
        for reply in [")(", "Entering (|||)(", ")1,2,3,4,5,6(", "no brackets", "(1,2,3)"] {
            var o = FakeFTPServer.Options(); o.passiveReply = reply
            try await withServer(o) { s in
                let c = client(s, .explicitTLS)
                try await c.connect()
                await expectError("bad_passive_reply") { _ = try await c.list("/") }
                await c.close()
            }
        }
    }

    func testCompletedControlReplyWithoutDataEOFIsBounded() async throws {
        var o = FakeFTPServer.Options(); o.holdDownloadOpen = true
        try await withServer(o) { s in
            s.seedFile("/x", Data("payload".utf8))
            let c = FTPClient(config: FTPConfig(host: "127.0.0.1", port: s.port, security: .explicitTLS,
                username: "ftpuser", password: "ftppass", verifyCertificate: false, timeout: 1),
                allowedNets: loopback, allowInsecure: true)
            try await c.connect()
            await expectError("timeout") { _ = try await c.download("/x") }
            await expectError("timeout") { _ = try await c.list("/") }
            await c.close()
        }
    }

    func testRepeatedUploadThenDownloadDoesNotUseClosedDataChannel() async throws {
        try await withServer { s in
            let c = client(s, .explicitTLS)
            try await c.connect()
            for i in 0..<30 {
                let bytes = Data("payload-\(i)".utf8)
                try await c.upload("/x", bytes)
                let back = try await c.download("/x")
                XCTAssertEqual(back, bytes)
            }
            await c.close()
        }
    }

    func testBlockedTargetIsRefusedBeforeAnyConnection() async throws {
        let c = FTPClient(config: FTPConfig(host: "127.0.0.1", port: 9, security: .explicitTLS, username: "u", password: "p"), allowedNets: [])
        await expectError("target_blocked") { try await c.connect() }
    }
}
