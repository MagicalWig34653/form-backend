// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
import XCTVapor
@testable import FormAuth
@testable import FormHTTP

final class TOTPHTTPTests: XCTestCase {
    func testPublicPasswordTOTPAndInternalRefusal() async throws {
        for listener in ["internal", "public"] {
            try await DBFixture.with { f in
                let key = try StaticServerKey(Data(repeating: 4, count: 32))
                let account = try await f.account(passwordHash: Argon2id.hash("synthetic-password"))
                try await f.sql.raw("UPDATE accounts SET username = 'synthetic' WHERE id = \(bind: DB.bin(account))").run()
                let date = Date(timeIntervalSince1970: 1800000000)
                let store = SecretStore(db: f.app.db(.mysql), keys: key)
                let service = TOTPService(db: f.app.db(.mysql), secrets: store, now: { date })
                _ = try await service.begin(account: account)
                struct R: Decodable { let pending_ref: String }
                let r = try await f.sql.raw("SELECT pending_ref FROM account_totp WHERE account_id = \(bind: DB.bin(account))").first(decoding: R.self)!
                let secret = try await store.get(r.pending_ref)!
                let step = Int64(date.timeIntervalSince1970 / 30)
                try await service.verify(account: account, code: TOTP.code(secret: secret, step: step), confirming: true)
                try HTTPSetup.configure(f.app)
                var cfg = AuthConfig(relyingParty: RelyingParty(rpID: "example.test", origin: "https://example.test"))
                cfg.listener = listener
                let g = FormAuth.register(f.app, config: cfg, keys: key, now: { date.addingTimeInterval(30) })
                let (token, _) = try await g.sessions.createAnonymous()
                let s = try await g.sessions.resolve(token: token)!
                let csrf = try await g.sessions.csrfToken(for: s)!
                var h = HTTPHeaders()
                h.contentType = .json
                h.add(name: .cookie, value: "\(SessionService.cookieName)=\(token)")
                h.add(name: "Origin", value: "https://example.test")
                h.add(name: "X-CSRF-Token", value: csrf)
                let body = "{\"username\":\"  synthetic  \",\"password\":\"synthetic-password\",\"code\":\"\(TOTP.code(secret: secret, step: step + 1))\"}"
                try await f.app.test(.POST, "admin/api/v1/auth/totp", headers: h, beforeRequest: { req async throws in req.body = .init(string: body) }) { res async throws in
                    XCTAssertEqual(res.status, listener == "public" ? .ok : .notFound, String(buffer: res.body))
                    if listener == "public" { XCTAssertTrue(String(buffer: res.body).contains("authenticated")) }
                }
            }
        }
    }
    func testPasswordThrottleUsesTrimmedUsername() async throws {
        try await DBFixture.with { f in
            let key = try StaticServerKey(Data(repeating: 4, count: 32))
            try HTTPSetup.configure(f.app)
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: "example.test", origin: "https://example.test"))
            cfg.listener = "public"
            let date = Date(timeIntervalSince1970: 1800000000)
            let g = FormAuth.register(f.app, config: cfg, keys: key, now: { date })
            let (token, s) = try await g.sessions.createAnonymous()
            let csrf = try await g.sessions.csrfToken(for: s)!
            var h: HTTPHeaders = ["Origin": "https://example.test", "X-CSRF-Token": csrf,
                "Cookie": "\(SessionService.cookieName)=\(token)"]
            h.contentType = .json
            for username in ["synthetic", "  synthetic  "] {
                let body = "{\"username\":\"\(username)\",\"password\":\"wrong\",\"code\":\"000000\"}"
                try await f.app.test(.POST, "admin/api/v1/auth/totp", headers: h, body: ByteBuffer(string: body)) { res async throws in
                    XCTAssertEqual(res.status, .unauthorized)
                }
            }
            struct C: Decodable { let failures: Int }
            let counters = try await f.sql.raw("SELECT failures FROM auth_throttles WHERE scope='account'").all(decoding: C.self)
            XCTAssertEqual(counters.count, 1)
            XCTAssertEqual(counters.first?.failures, 2)
            let throttle = ThrottleService(db: f.app.db(.mysql), keys: key, now: { date })
            try await throttle.recordFailure(.account, "totp-password|synthetic", policy: .init(limit: 1, window: 900, lock: 900, backoff: false))
            for username in ["synthetic", " synthetic ", "  synthetic  "] {
                let body = "{\"username\":\"\(username)\",\"password\":\"wrong\",\"code\":\"000000\"}"
                try await f.app.test(.POST, "admin/api/v1/auth/totp", headers: h, body: ByteBuffer(string: body)) { res async throws in
                    XCTAssertEqual(res.status, .tooManyRequests)
                }
            }
        }
    }

}
