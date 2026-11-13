// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormAuth

final class FileServerKeyTests: XCTestCase {
    private func write(_ content: String, mode: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fsk-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key").path
        FileManager.default.createFile(atPath: path, contents: Data(content.utf8), attributes: [.posixPermissions: mode])
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return path
    }

    func testReadsHexKeyWithRestrictivePermissions() async throws {
        let hex = String(repeating: "ab", count: 32)
        let k = try FileServerKey(path: try write(hex + "\n", mode: 0o600))
        _ = try await k.serverKey()
        _ = try FileServerKey(path: try write(hex.uppercased(), mode: 0o400))
    }

    func testRejectsLooseModeBadFormatAndMissingFile() throws {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertThrowsError(try FileServerKey(path: try write(hex, mode: 0o644))) { XCTAssertEqual($0 as? FileServerKey.LoadError, .permissions) }
        XCTAssertThrowsError(try FileServerKey(path: try write(hex, mode: 0o640))) { XCTAssertEqual($0 as? FileServerKey.LoadError, .permissions) }
        for bad in ["", "ab", String(repeating: "g", count: 64), hex + "ab", String(repeating: "ab", count: 31)] {
            XCTAssertThrowsError(try FileServerKey(path: try write(bad, mode: 0o600))) { XCTAssertEqual($0 as? FileServerKey.LoadError, .format) }
        }
        XCTAssertThrowsError(try FileServerKey(path: "/nonexistent/key")) { XCTAssertEqual($0 as? FileServerKey.LoadError, .unreadable) }
        XCTAssertThrowsError(try FileServerKey(path: FileManager.default.temporaryDirectory.path)) { XCTAssertEqual($0 as? FileServerKey.LoadError, .unreadable) }
    }
}
