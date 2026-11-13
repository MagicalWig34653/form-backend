// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormCore

final class AdminConfigTests: XCTestCase {
    private let base = ["FORM_DB_PASSWORD": "pw"]
    private func cfg(_ extra: [String: String]) throws -> AppConfig { try AppConfig(env: base.merging(extra) { $1 }) }
    private let all = ["FORM_SERVER_KEY_FILE": "/run/key", "FORM_ADMIN_ORIGIN": "https://admin.example.test", "FORM_RP_ID": "admin.example.test"]

    func testAbsentMeansDisabledAndComplete() throws {
        XCTAssertNil(try cfg([:]).admin)
        XCTAssertEqual(try cfg(all).admin, AdminConfig(serverKeyFile: "/run/key", origin: "https://admin.example.test", rpID: "admin.example.test"))
        XCTAssertNoThrow(try cfg(all.merging(["FORM_RP_ID": "example.test"]) { $1 }))   // registrable suffix
    }

    func testPartialOrBadValuesAreRejectedWithoutEchoingThem() {
        for key in all.keys {
            var partial = all; partial[key] = nil
            XCTAssertThrowsError(try cfg(partial), key)
        }
        let bad: [[String: String]] = [
            ["FORM_ADMIN_ORIGIN": "http://admin.example.test"], ["FORM_ADMIN_ORIGIN": "https://admin.example.test/"],
            ["FORM_ADMIN_ORIGIN": "https://admin.example.test/x"], ["FORM_ADMIN_ORIGIN": "https://u:p@admin.example.test"],
            ["FORM_ADMIN_ORIGIN": "admin.example.test"], ["FORM_RP_ID": "Admin.Example.test"], ["FORM_RP_ID": "other.test"],
            ["FORM_RP_ID": "admin.example.test:443"], ["FORM_RP_ID": "evilexample.test"],
        ]
        for b in bad {
            XCTAssertThrowsError(try cfg(all.merging(b) { $1 }), "\(b)") { err in
                XCTAssertFalse("\(err)".contains("secret"), "no values in errors")
            }
        }
        XCTAssertNoThrow(try cfg(all.merging(["FORM_ADMIN_ORIGIN": "http://localhost:8080", "FORM_RP_ID": "localhost", "FORM_ALLOW_INSECURE_DEV": "1"]) { $1 }))
    }
}

final class PasswordFileTests: XCTestCase {
    private func file(_ content: String) throws -> String {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("pw-" + UUID().uuidString).path
        try content.write(toFile: p, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: p) }
        return p
    }
    func testPasswordFromSecretFile() throws {
        let c = try AppConfig(env: ["FORM_DB_PASSWORD_FILE": try file("s3cret\n")])
        XCTAssertEqual(c.dbPassword, "s3cret")
        // the direct variable wins; empty file / missing file / nothing at all fail without echoing values
        XCTAssertEqual(try AppConfig(env: ["FORM_DB_PASSWORD": "direct", "FORM_DB_PASSWORD_FILE": try file("other")]).dbPassword, "direct")
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD_FILE": try file("\n")]))
        XCTAssertThrowsError(try AppConfig(env: ["FORM_DB_PASSWORD_FILE": "/nonexistent/pw"]))
        XCTAssertThrowsError(try AppConfig(env: [:]))
    }
}
