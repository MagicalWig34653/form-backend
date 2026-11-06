// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormAuth

final class PasswordVerifierTests: XCTestCase {
    /// Produced by PHP 8.5 `password_hash("correct horse battery", PASSWORD_ARGON2ID, [memory_cost=>19456,time_cost=>2,threads=>1])`.
    private let phpArgon2id = "$argon2id$v=19$m=19456,t=2,p=1$OHExVWRXUGxoVXl6eXVndQ$F2q28Yuzm3L71JeRIePRRcuFOmGze6MtzfKZBRb3T6I"
    /// PHP defaults (m=65536, t=4): different parameters must verify as well.
    private let phpDefaults = "$argon2id$v=19$m=65536,t=4,p=1$eURObVhQMWZjc2tXQlhpZw$q4j6XjyJ5cg6Es+Rc/mVK5HrZLg1aAn4FgqEXyl+Z9U"
    /// PHP `password_hash("correct horse battery", PASSWORD_BCRYPT, ["cost"=>10])`.
    private let phpBcrypt = "$2y$10$zpmW.4mcsmGZBzgu7l5YY.jvQr4TtJ3QtoDUVIgSfFGfhp46QRiY2"

    func testVerifiesHashesProducedByPHP() async {
        let v = DefaultPasswordVerifier()
        for h in [phpArgon2id, phpDefaults] {
            let ok = await v.verify(password: "correct horse battery", hash: h)
            let wrong = await v.verify(password: "correct horse batterY", hash: h)
            XCTAssertTrue(ok); XCTAssertFalse(wrong)
        }
    }

    func testLegacyBcryptStillWorksButRefusesWrongPassword() async {
        let v = DefaultPasswordVerifier()
        let ok = await v.verify(password: "correct horse", hash: phpBcrypt)
        let bad = await v.verify(password: "nope", hash: phpBcrypt)
        XCTAssertTrue(ok); XCTAssertFalse(bad)
    }

    func testHashRoundTripAndPHPCompatibleFormat() throws {
        let h = try Argon2id.hash("pässword ✓ \u{0}x")   // non-ASCII and embedded NUL are part of the secret
        XCTAssertTrue(h.hasPrefix("$argon2id$v=19$m=19456,t=2,p=1$"))
        XCTAssertTrue(Argon2id.verify("pässword ✓ \u{0}x", encoded: h))
        XCTAssertFalse(Argon2id.verify("pässword ✓ ", encoded: h))
        XCTAssertNotEqual(try Argon2id.hash("same"), try Argon2id.hash("same"), "random salt")
    }

    func testMalformedUnknownAndEmptyFailClosed() async {
        let v = DefaultPasswordVerifier()
        for bad in ["", "plain", "$argon2i$v=19$m=19456,t=2,p=1$OHExVWRXUGxoVXl6eXVndQ$F2q28Yuzm3L71JeRIePRRcuFOmGze6MtzfKZBRb3T6I",
                    "$argon2id$v=19$m=19456,t=2,p=1$OHExVWRXUGxoVXl6eXVndQ$", "$argon2id$", "$argon2id$v=19$m=1,t=1,p=1$AAAA$AAAA",
                    "$2y$10$short", "{SHA}x", "$1$md5$hash"] {
            let r = await v.verify(password: "correct horse battery", hash: bad)
            XCTAssertFalse(r, bad)
        }
        let none = await v.verify(password: "x", hash: nil)
        XCTAssertFalse(none)
        XCTAssertFalse(Argon2id.verify("x", encoded: "$argon2id$v=19$m=19456,t=2,p=1$not-base64$also-not"))
    }

    func testRehashDecision() throws {
        XCTAssertFalse(Argon2id.needsRehash(phpArgon2id))
        XCTAssertFalse(Argon2id.needsRehash(phpDefaults))          // stronger than the target
        XCTAssertTrue(Argon2id.needsRehash(phpBcrypt))
        XCTAssertTrue(Argon2id.needsRehash("$argon2id$v=19$m=4096,t=1,p=1$AAAAAAAAAAA$AAAAAAAAAAA"))
        XCTAssertTrue(Argon2id.needsRehash("garbage"))
        XCTAssertEqual(Argon2id.parameters(of: phpArgon2id), { var p = Argon2Parameters(); p.memoryKiB = 19456; p.iterations = 2; p.parallelism = 1; return p }())
    }

    func testDummyPathCostsAboutAsMuchAsARealVerification() async {
        let v = DefaultPasswordVerifier()
        func time(_ h: String?) async -> Double {
            let t = Date()
            _ = await v.verify(password: "correct horse battery", hash: h)
            return Date().timeIntervalSince(t)
        }
        _ = await time(phpArgon2id) // warm up
        var real = 0.0, dummy = 0.0
        for _ in 0..<3 { real += await time(phpArgon2id); dummy += await time(nil) }
        // Same order of magnitude (a missing hash must not answer noticeably faster); generous bound against CI noise.
        XCTAssertGreaterThan(dummy / max(real, 0.0001), 0.3, "dummy \(dummy) vs real \(real)")
        XCTAssertLessThan(dummy / max(real, 0.0001), 3.0, "dummy \(dummy) vs real \(real)")
    }
}
