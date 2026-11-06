// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest

/// The FormAuth copy of the passkey code must stay in step with backend/poc-passkey (ADR 0008 F9).
final class PasskeyParityTests: XCTestCase {
    func testVectorsIdenticalToPoC() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let poc = root.appendingPathComponent("poc-passkey/Tests/PasskeyPoCTests/Fixtures/vectors.json")
        let copy = root.appendingPathComponent("Tests/FormAuthTests/Fixtures/vectors.json")
        XCTAssertEqual(try Data(contentsOf: poc), try Data(contentsOf: copy))
    }

    func testSourcesIdenticalToPoCExceptHeader() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for f in ["AssertionVerifier", "LoginFlow", "PasskeyKey"] {
            let poc = try String(contentsOf: root.appendingPathComponent("poc-passkey/Sources/PasskeyPoC/\(f).swift"), encoding: .utf8)
            let copy = try String(contentsOf: root.appendingPathComponent("Sources/FormAuth/Passkey/\(f).swift"), encoding: .utf8)
            let body = copy.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            XCTAssertEqual(body, poc, "\(f).swift diverged from the PoC copy")
        }
    }
}
