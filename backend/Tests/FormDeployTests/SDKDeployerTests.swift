// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import Foundation
import TestSupport
import XCTest
@testable import FormDeploy

final class SDKDeployerTests: XCTestCase {
    private let loopback = [CIDR("127.0.0.0/8")!]
    private func bundle(_ v: String, marker: String = "") -> SDKBundle {
        SDKBundle(version: v, items: [
            .init(path: "VERSION", data: Data("\(v)\n".utf8)), .init(path: "src/Client.php", data: Data("<?php // client \(v) \(marker)\n".utf8)),
            .init(path: "src/Canonical.php", data: Data("<?php // canonical\n".utf8)), .init(path: "bin/submit.php", data: Data("<?php // cli\n".utf8)),
        ])
    }
    private func connect(_ s: FakeFTPServer) async throws -> SDKDeployer {
        let c = FTPClient(config: FTPConfig(host: "127.0.0.1", port: s.port, security: .explicitTLS, username: "ftpuser", password: "ftppass", verifyCertificate: false, timeout: 5), allowedNets: loopback, allowInsecure: true)
        try await c.connect()
        return SDKDeployer(client: c)
    }
    private func server(_ o: FakeFTPServer.Options = .init(), _ body: (FakeFTPServer) async throws -> Void) async throws {
        let s = FakeFTPServer(o); s.seedDir("/htdocs"); s.seedDir("/htdocs/lib"); s.seedFile("/htdocs/lib/credentials.json", Data("{\"keep\":true}".utf8))
        try await s.start()
        do { try await body(s) } catch { await s.stop(); throw error }
        await s.stop()
    }

    func testInstallUpdateRollbackKeepsOneVersionAndNeverTouchesOtherFiles() async throws {
        try await server { s in
            let d = try await connect(s)
            let dir = "/htdocs/lib/form-sdk"
            // first installation
            var out = try await d.install(bundle("0.2.0"), to: dir)
            XCTAssertEqual(out, .installed(version: "0.2.0", previous: nil))
            XCTAssertEqual(s.files[dir + "/VERSION"], Data("0.2.0\n".utf8))
            XCTAssertEqual(s.files[dir + "/src/Client.php"], bundle("0.2.0").items[1].data)
            XCTAssertNil(s.dirs.first { $0.contains(".staging") }, "no staging directory is left behind")
            // update: the old version becomes .prev
            out = try await d.install(bundle("0.3.0"), to: dir)
            XCTAssertEqual(out, .installed(version: "0.3.0", previous: "0.2.0"))
            XCTAssertEqual(s.files[dir + ".prev/VERSION"], Data("0.2.0\n".utf8))
            // a third update drops the oldest, only one previous version stays
            _ = try await d.install(bundle("0.3.1"), to: dir)
            XCTAssertEqual(s.files[dir + ".prev/VERSION"], Data("0.3.0\n".utf8))
            let installedNow = await d.installedVersion(dir), prevNow = await d.previousVersion(dir)
            XCTAssertEqual(installedNow, "0.3.1"); XCTAssertEqual(prevNow, "0.3.0")
            // rollback swaps: the failed version stays as .prev (a second rollback is a roll-forward)
            let rb = try await d.rollback(dir)
            XCTAssertEqual(rb, .rolledBack(to: "0.3.0"))
            XCTAssertEqual(s.files[dir + "/VERSION"], Data("0.3.0\n".utf8)); XCTAssertEqual(s.files[dir + ".prev/VERSION"], Data("0.3.1\n".utf8))
            // the customer's own files next to the SDK were never touched
            XCTAssertEqual(s.files["/htdocs/lib/credentials.json"], Data("{\"keep\":true}".utf8))
            await d.client.close()
        }
    }

    func testDowngradeInstallIsRefusedAndInvalidPathsToo() async throws {
        try await server { s in
            let d = try await connect(s)
            _ = try await d.install(bundle("0.4.0"), to: "/htdocs/lib/form-sdk")
            do { _ = try await d.install(bundle("0.3.0"), to: "/htdocs/lib/form-sdk"); XCTFail() } catch let e as FTPError { XCTAssertEqual(e.code, "downgrade_refused") }
            for bad in ["/", "/x", "relative/path", "/a/../b", "/a/b/", "/a/b c/../d", "/a/b\n/c", "/htdocs/lib/%s"] {
                do { _ = try await d.install(bundle("0.5.0"), to: bad); XCTFail(bad) } catch let e as FTPError { XCTAssertTrue(["path_invalid", "parent_missing"].contains(e.code), "\(bad): \(e.code)") }
            }
            do { _ = try await d.rollback("/htdocs/lib/other-sdk"); XCTFail() } catch let e as FTPError { XCTAssertEqual(e.code, "no_previous_version") }
            await d.client.close()
        }
    }

    func testCorruptedStorageIsDetectedAndLeavesTheLiveVersionAlone() async throws {
        var o = FakeFTPServer.Options(); o.corruptUploadsNamed = "Client.php"
        try await server(o) { s in
            let d = try await connect(s)
            let dir = "/htdocs/lib/form-sdk"
            s.seedDir(dir); s.seedFile(dir + "/VERSION", Data("0.1.0\n".utf8)); s.seedDir(dir + "/src"); s.seedFile(dir + "/src/Client.php", Data("old".utf8))
            do { _ = try await d.install(bundle("0.2.0"), to: dir); XCTFail() } catch let e as FTPError { XCTAssertEqual(e.code, "verify_failed") }
            XCTAssertEqual(s.files[dir + "/VERSION"], Data("0.1.0\n".utf8), "the live directory was never swapped")
            XCTAssertEqual(s.files[dir + "/src/Client.php"], Data("old".utf8))
            XCTAssertNil(s.dirs.first { $0.contains(".staging") }, "staging cleaned up after the failure")
            await d.client.close()
        }
    }

    func testRefusedRenamesOntoTheLivePathAreRepairRequired() async throws {
        // the server refuses EVERY rename onto the live path, so putting the old version back fails too (review Astra 2 M2):
        // that is reported as repair_required, and the old version is kept as .prev to repair from
        var o = FakeFTPServer.Options(); o.failRenameTo = "/form-sdk"
        try await server(o) { s in
            let d = try await connect(s)
            let dir = "/htdocs/lib/form-sdk"
            s.seedDir(dir); s.seedFile(dir + "/VERSION", Data("0.1.0\n".utf8)); s.seedDir(dir + "/src"); s.seedFile(dir + "/src/Client.php", Data("old".utf8))
            do { _ = try await d.install(bundle("0.2.0"), to: dir); XCTFail() } catch let e as FTPError { XCTAssertEqual(e.code, "repair_required") }
            XCTAssertNil(s.files[dir + "/VERSION"], "live is really missing")
            XCTAssertEqual(s.files[dir + ".prev/VERSION"], Data("0.1.0\n".utf8))
            XCTAssertEqual(s.files[dir + ".prev/src/Client.php"], Data("old".utf8))
            XCTAssertNil(s.dirs.first { $0.contains(".staging") })
            await d.client.close()
        }
    }

    func testBundleLoadsTheRealSDKAndRefusesSymlinksAndBadVersions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let real = try SDKBundle.load(from: root.appendingPathComponent("sdk/php"))
        XCTAssertTrue(real.items.contains { $0.path == "src/Client.php" }); XCTAssertTrue(real.items.contains { $0.path == "bin/submit.php" })
        XCTAssertFalse(real.items.contains { $0.path.hasPrefix("tests/") }, "tests are not shipped")
        XCTAssertEqual(real.version.split(separator: ".").count, 3)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("sdkb-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data("1.0\n".utf8).write(to: tmp.appendingPathComponent("VERSION"))
        XCTAssertThrowsError(try SDKBundle.load(from: tmp))
        try Data("1.0.0\n".utf8).write(to: tmp.appendingPathComponent("VERSION"))
        try Data("<?php".utf8).write(to: tmp.appendingPathComponent("src/a.php"))
        try FileManager.default.createSymbolicLink(at: tmp.appendingPathComponent("src/evil.php"), withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        XCTAssertThrowsError(try SDKBundle.load(from: tmp))
        XCTAssertEqual(SDKBundle.compare("0.10.0", "0.9.9"), 1); XCTAssertEqual(SDKBundle.compare("1.0.0", "1.0.0"), 0)
    }
}

/// In-memory remote tree with symlinks, to prove that recursive removal never follows a link out of the tree (review H3).
class LinkAwareClient: RemoteFileClient, @unchecked Sendable {
    enum Node { case file, dir, link(String) }
    var nodes: [String: Node] = [:]
    var deleted: [String] = []
    func connect() async throws {}
    func close() async {}
    func exists(_ p: String) async -> Bool { nodes[p] != nil }
    func isDirectory(_ p: String) async -> Bool { if case .dir? = nodes[p] { return true }; return false }   // lstat semantics
    func makeDirectory(_ p: String) async throws { nodes[p] = .dir }
    func upload(_ p: String, _ d: Data) async throws { nodes[p] = .file }
    func download(_ p: String, limit: Int) async throws -> Data { Data() }
    func rename(_ a: String, _ b: String) async throws {}
    func delete(_ p: String) async throws {
        switch nodes[p] { case .file?, .link?: nodes[p] = nil; deleted.append(p); default: throw FTPError("ftp_550") }   // a directory refuses a plain delete
    }
    func removeDirectory(_ p: String) async throws { nodes[p] = nil; deleted.append(p + "/") }
    func list(_ d: String) async throws -> [String] { nodes.keys.filter { $0.hasPrefix(d + "/") && !$0.dropFirst(d.count + 1).contains("/") }.map { String($0.dropFirst(d.count + 1)) } }
}

final class RemoveTreeTests: XCTestCase {
    func testLinkInsideTheTreeIsRemovedButNeverEntered() async throws {
        let c = LinkAwareClient()
        c.nodes = ["/w/sdk.prev": .dir, "/w/sdk.prev/a.php": .file, "/w/sdk.prev/out": .link("/w/other"),
                   "/w/other": .dir, "/w/other/keep.txt": .file]
        try await SDKDeployer(client: c).removeTree("/w/sdk.prev")
        XCTAssertNil(c.nodes["/w/sdk.prev"]); XCTAssertNil(c.nodes["/w/sdk.prev/out"])
        XCTAssertNotNil(c.nodes["/w/other/keep.txt"], "content behind the link must stay untouched")
    }

    func testUnsafeEntryNamesAreRefused() async throws {
        final class Evil: LinkAwareClient, @unchecked Sendable {
            override func list(_ d: String) async throws -> [String] { ["../../x"] }
        }
        let c = Evil(); c.nodes = ["/w/t": .dir]
        do { try await SDKDeployer(client: c).removeTree("/w/t"); XCTFail("expected path_invalid") } catch let e as FTPError { XCTAssertEqual(e.code, "path_invalid") }
    }

    func testExistingDirectoryWithoutReadableVersionIsNotReplaced() async throws {
        let c = LinkAwareClient()
        c.nodes = ["/w": .dir, "/w/sdk": .dir, "/w/sdk/something.txt": .file]
        let b = SDKBundle(version: "0.1.0", items: [.init(path: "VERSION", data: Data("0.1.0\n".utf8)), .init(path: "src/a.php", data: Data())])
        do { _ = try await SDKDeployer(client: c).install(b, to: "/w/sdk"); XCTFail("expected version_unknown") } catch let e as FTPError { XCTAssertEqual(e.code, "version_unknown") }
    }

    func testVersionComparisonRejectsOversizedComponents() {
        XCTAssertNil("999999999999999999999999.0.0".range(of: SDKBundle.versionPattern, options: .regularExpression))
        XCTAssertGreaterThan(SDKBundle.compare("0.10.0", "0.9.9"), 0)
    }
}

/// In-memory remote tree with real rename semantics and injectable rename failures (review Astra 2 M2: fault injection after every rename).
final class TreeClient: RemoteFileClient, @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: Data] = [:]
    var dirs: Set<String> = ["/", "/w"]
    /// a rename whose (from, to) matches is refused; each entry fires once
    var failRenames: [(from: String, to: String)] = []
    /// a rename whose (from, to) matches IS executed, but its answer is lost (timeout); each entry fires once
    var lostReplies: [(from: String, to: String)] = []
    var renames: [String] = []
    func connect() async throws {}
    func close() async {}
    func exists(_ p: String) async -> Bool { lock.lock(); defer { lock.unlock() }; return files[p] != nil || dirs.contains(p) }
    func isDirectory(_ p: String) async -> Bool { lock.lock(); defer { lock.unlock() }; return dirs.contains(p) }
    func makeDirectory(_ p: String) async throws { lock.lock(); dirs.insert(p); lock.unlock() }
    func upload(_ p: String, _ d: Data) async throws { lock.lock(); files[p] = d; lock.unlock() }
    func download(_ p: String, limit: Int) async throws -> Data { lock.lock(); defer { lock.unlock() }; guard let d = files[p] else { throw FTPError("ftp_550_retr") }; return d }
    func rename(_ a: String, _ b: String) async throws {
        lock.lock(); defer { lock.unlock() }
        if let i = failRenames.firstIndex(where: { $0.from == a && $0.to == b }) { failRenames.remove(at: i); throw FTPError("ftp_550_rnto") }
        guard files[b] == nil, !dirs.contains(b), files[a] != nil || dirs.contains(a) else { throw FTPError("ftp_550_rnto") }
        renames.append("\(a)->\(b)")
        if let d = files.removeValue(forKey: a) { files[b] = d }
        else {
            for k in files.keys where k.hasPrefix(a + "/") { files[b + k.dropFirst(a.count)] = files.removeValue(forKey: k) }
            for k in dirs where k == a || k.hasPrefix(a + "/") { dirs.remove(k); dirs.insert(b + k.dropFirst(a.count)) }
        }
        if let i = lostReplies.firstIndex(where: { $0.from == a && $0.to == b }) { lostReplies.remove(at: i); throw FTPError("timeout") }
    }
    func delete(_ p: String) async throws { lock.lock(); defer { lock.unlock() }; guard files.removeValue(forKey: p) != nil else { throw FTPError("ftp_550_dele") } }
    func removeDirectory(_ p: String) async throws { lock.lock(); defer { lock.unlock() }; guard dirs.remove(p) != nil else { throw FTPError("ftp_550_rmd") } }
    func list(_ d: String) async throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        let children = files.keys.filter { $0.hasPrefix(d + "/") } + dirs.filter { $0.hasPrefix(d + "/") }
        return Array(Set(children.compactMap { $0.dropFirst(d.count + 1).split(separator: "/").first.map(String.init) }))
    }
    func seedVersion(_ dir: String, _ v: String) { dirs.insert(dir); files[dir + "/VERSION"] = Data("\(v)\n".utf8); files[dir + "/src.php"] = Data("<?php // \(v)".utf8) }
    func version(_ dir: String) -> String? { files[dir + "/VERSION"].map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } }
}

final class DeployRecoveryTests: XCTestCase {
    private let dir = "/w/sdk", prev = "/w/sdk.prev", staging = "/w/.sdk.staging", swap = "/w/.sdk.swap"
    private func bundle(_ v: String) -> SDKBundle { SDKBundle(version: v, items: [.init(path: "VERSION", data: Data("\(v)\n".utf8)), .init(path: "src.php", data: Data("<?php // \(v)".utf8))]) }
    private final class Phases: @unchecked Sendable { var list: [String] = []; let l = NSLock(); func add(_ s: String) { l.lock(); list.append(s); l.unlock() } }
    private func code(_ f: () async throws -> Void) async -> String? {
        do { try await f(); return nil } catch let e as FTPError { return e.code } catch { return "\(error)" }
    }

    func testFailedSwapRestoresTheLivePathItself() async {
        let c = TreeClient(); c.seedVersion(dir, "0.1.0"); c.failRenames = [(staging, dir)]
        let e = await code { _ = try await SDKDeployer(client: c).install(self.bundle("0.2.0"), to: self.dir) }
        XCTAssertEqual(e, "swap_failed")
        XCTAssertEqual(c.version(dir), "0.1.0", "the old version is live again under the live path, not only as .prev")
        XCTAssertFalse(c.dirs.contains(staging))
    }

    func testFailedRestoreAfterSwapIsRepairRequiredNotSwallowed() async {
        let c = TreeClient(); c.seedVersion(dir, "0.1.0"); c.failRenames = [(staging, dir), (prev, dir)]
        let ph = Phases()
        let e = await code { _ = try await SDKDeployer(client: c, phase: { ph.add($0) }).install(self.bundle("0.2.0"), to: self.dir) }
        XCTAssertEqual(e, "repair_required", "live is missing: this must never look like a plain failed update")
        XCTAssertEqual(c.version(prev), "0.1.0", "the old version is still there to repair from")
        XCTAssertEqual(ph.list, ["upload", "swap"], "phases are reported before the remote changes")
    }

    func testRollbackFailuresAreRepairRequiredAndKeepEveryVersion() async {
        // prev -> live fails, and putting the current version back fails too: live is gone
        var c = TreeClient(); c.seedVersion(dir, "0.2.0"); c.seedVersion(prev, "0.1.0"); c.failRenames = [(prev, dir), (swap, dir)]
        var e = await code { _ = try await SDKDeployer(client: c).rollback(self.dir) }
        XCTAssertEqual(e, "repair_required")
        XCTAssertEqual(c.version(swap), "0.2.0"); XCTAssertEqual(c.version(prev), "0.1.0")
        // the last step (failed version -> .prev) fails: live is right, but the state is incomplete and must not be reported as success
        c = TreeClient(); c.seedVersion(dir, "0.2.0"); c.seedVersion(prev, "0.1.0"); c.failRenames = [(swap, prev)]
        e = await code { _ = try await SDKDeployer(client: c).rollback(self.dir) }
        XCTAssertEqual(e, "repair_required")
        XCTAssertEqual(c.version(dir), "0.1.0"); XCTAssertEqual(c.version(swap), "0.2.0")
        // prev -> live fails but the current version goes back: a plain failure
        c = TreeClient(); c.seedVersion(dir, "0.2.0"); c.seedVersion(prev, "0.1.0"); c.failRenames = [(prev, dir)]
        e = await code { _ = try await SDKDeployer(client: c).rollback(self.dir) }
        XCTAssertEqual(e, "swap_failed"); XCTAssertEqual(c.version(dir), "0.2.0"); XCTAssertEqual(c.version(prev), "0.1.0")
    }

    func testLeftoverSwapDirectoryIsNeverDeleted() async {
        // .swap can hold the only copy of a formerly live version (interrupted rollback): neither install nor rollback may remove it
        for action in ["install", "rollback"] {
            let c = TreeClient(); c.seedVersion(prev, "0.1.0"); c.seedVersion(swap, "0.2.0")
            let e = await code {
                if action == "install" { _ = try await SDKDeployer(client: c).install(self.bundle("0.3.0"), to: self.dir) } else { _ = try await SDKDeployer(client: c).rollback(self.dir) }
            }
            XCTAssertEqual(e, "repair_required", action)
            XCTAssertEqual(c.version(swap), "0.2.0", action); XCTAssertEqual(c.version(prev), "0.1.0", action)
        }
    }

    func testInstallAfterAnInterruptedSwapKeepsThePreviousVersion() async throws {
        // a crash after live -> .prev: live is missing; a new install fills live and leaves the only old copy alone
        let c = TreeClient(); c.seedVersion(prev, "0.1.0"); c.seedVersion(staging, "0.2.0")
        let out = try await SDKDeployer(client: c).install(bundle("0.2.0"), to: dir)
        XCTAssertEqual(out, .installed(version: "0.2.0", previous: "0.1.0"), "previous is what .prev really holds, not a remembered value")
        XCTAssertEqual(c.version(dir), "0.2.0"); XCTAssertEqual(c.version(prev), "0.1.0")
    }

    // Gegenlesen Astra 2: a rename the server executed but never confirmed leaves an unclear state: repair_required, not swap_failed.
    func testUnconfirmedRenamesAreRepairRequired() async {
        for lost in [(dir, prev), (staging, dir)] {
            let c = TreeClient(); c.seedVersion(dir, "0.1.0"); c.lostReplies = [lost]
            let e = await code { _ = try await SDKDeployer(client: c).install(self.bundle("0.2.0"), to: self.dir) }
            XCTAssertEqual(e, "repair_required", "\(lost)")
            XCTAssertTrue(c.version(dir) != nil || c.version(prev) == "0.1.0", "no version is deleted after an unclear rename")
        }
        for lost in [(dir, swap), (prev, dir)] {
            let c = TreeClient(); c.seedVersion(dir, "0.2.0"); c.seedVersion(prev, "0.1.0"); c.lostReplies = [lost]
            let e = await code { _ = try await SDKDeployer(client: c).rollback(self.dir) }
            XCTAssertEqual(e, "repair_required", "\(lost)")
        }
        // an explicit refusal is still a plain failure with live intact
        let c = TreeClient(); c.seedVersion(dir, "0.1.0"); c.failRenames = [(dir, prev)]
        let e = await code { _ = try await SDKDeployer(client: c).install(self.bundle("0.2.0"), to: self.dir) }
        XCTAssertEqual(e, "swap_failed"); XCTAssertEqual(c.version(dir), "0.1.0")
    }

    // Gegenlesen Astra 2: the same version is skipped; .prev keeps the real previous version.
    func testSameVersionIsNotInstalledOverItself() async throws {
        let c = TreeClient(); c.seedVersion(dir, "0.2.0"); c.seedVersion(prev, "0.1.0")
        let ph = Phases()
        let out = try await SDKDeployer(client: c, phase: { ph.add($0) }).install(bundle("0.2.0"), to: dir)
        XCTAssertEqual(out, .unchanged(version: "0.2.0", previous: "0.1.0"))
        XCTAssertEqual(c.version(dir), "0.2.0"); XCTAssertEqual(c.version(prev), "0.1.0")
        XCTAssertTrue(c.renames.isEmpty); XCTAssertTrue(ph.list.isEmpty, "no remote change, no phase")
    }

    // Codex 9: an empty live directory replaces .prev; the old .prev version is gone and must not be claimed.
    func testEmptyLiveDirectoryReplacesPreviousAndClaimsNone() async throws {
        let c = TreeClient(); c.dirs.insert(dir); c.seedVersion(prev, "0.1.0")
        let out = try await SDKDeployer(client: c).install(bundle("0.2.0"), to: dir)
        XCTAssertEqual(out, .installed(version: "0.2.0", previous: nil))
        XCTAssertNil(c.version(prev))
    }

    func testOverlapIgnoresCase() {
        XCTAssertTrue(SDKDeployer.overlaps("/web/SDK", "/web/sdk"))
        XCTAssertTrue(SDKDeployer.overlaps("/Web/lib", "/web/LIB/sdk"))
        XCTAssertFalse(SDKDeployer.overlaps("/web/sdk-a", "/web/sdk-b"))
    }
}
