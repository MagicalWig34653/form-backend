// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAuth

final class TOTPDBTests: XCTestCase {
    func testParallelConsumptionAndAuditRollback() async throws {
        try await DBFixture.with { f in
            let account = try await f.account()
            let store = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 6, count: 32)))
            let date = Date(timeIntervalSince1970: 1800000000)
            let service = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date })
            _ = try await service.begin(account: account)
            struct R: Decodable { let pending_ref: String }
            let r = try await f.sql.raw("SELECT pending_ref FROM account_totp WHERE account_id = \(bind: DB.bin(account))").first(decoding: R.self)!
            let secret = try await store.get(r.pending_ref)!
            let step = Int64(date.timeIntervalSince1970 / 30)
            let code = TOTP.code(secret: secret, step: step)
            try await f.sql.raw("CREATE TRIGGER reject_totp_audit BEFORE INSERT ON audit_events FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'synthetic audit failure'").run()
            do { try await service.verify(account: account, code: code, confirming: true); XCTFail("audit must roll back confirmation") } catch { }
            let enabled = try await service.enabled(account: account)
            XCTAssertFalse(enabled)
            try await f.sql.raw("DROP TRIGGER reject_totp_audit").run()
            try await service.verify(account: account, code: code, confirming: true)
            let later = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date.addingTimeInterval(30) })
            let nextCode = TOTP.code(secret: secret, step: step + 1)
            let successes = await withTaskGroup(of: Int.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do { try await later.verify(account: account, code: nextCode); return 1 }
                        catch { return 0 }
                    }
                }
                var total = 0
                for await value in group { total += value }
                return total
            }
            XCTAssertEqual(successes, 1)
        }
    }

    func testConfirmationLockoutReplayRemovalAndRotation() async throws {
        try await DBFixture.with { f in
            let account = try await f.account(passwordHash: Argon2id.hash("synthetic-password"))
            let key = try StaticServerKey(Data(repeating: 4, count: 32))
            let store = SecretStore(db: f.app.db(.mysql), keys: key)
            let date = Date(timeIntervalSince1970: 1800000000)
            let service = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date })
            _ = try await service.begin(account: account)
            let before = try await service.enabled(account: account)
            XCTAssertFalse(before)
            struct R: Decodable { let pending_ref: String }
            let row = try await f.sql.raw("SELECT pending_ref FROM account_totp WHERE account_id = \(bind: DB.bin(account))").first(decoding: R.self)!
            let secret = try await store.get(row.pending_ref)!
            let step = Int64(date.timeIntervalSince1970 / 30)
            try await service.verify(account: account, code: TOTP.code(secret: secret, step: step), confirming: true)
            let enabledAfter = try await service.enabled(account: account)
            XCTAssertTrue(enabledAfter)
            // Replay is a failed attempt; five attempts persist across service instances.
            for _ in 0..<5 {
                do { try await service.verify(account: account, code: TOTP.code(secret: secret, step: step)); XCTFail("replay accepted") }
                catch is AuthenticationFailed { }
            }
            let next = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date.addingTimeInterval(899) })
            do { try await next.verify(account: account, code: "000000"); XCTFail("lock missing") }
            catch is RateLimited { }
            let later = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date.addingTimeInterval(900) })
            try await later.verify(account: account, code: TOTP.code(secret: secret, step: step + 30))
            let rotated = SecretStore(db: f.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 5, count: 32)))
            try await rotated.reencrypt(from: store)
            let opened = try await rotated.get(row.pending_ref)
            XCTAssertEqual(opened, secret)
            let wrongKey = try await store.get(row.pending_ref)
            XCTAssertNil(wrongKey)
            let rotatedService = TOTPService(db: f.app.db(.mysql), secrets: rotated)
            do { try await rotatedService.remove(account: account, password: "wrong"); XCTFail() } catch { }
            try await rotatedService.remove(account: account, password: "synthetic-password")
            let enabled = try await rotatedService.enabled(account: account)
            XCTAssertFalse(enabled)
            let removed = try await rotated.get(row.pending_ref)
            XCTAssertNil(removed)
        }
    }
}
