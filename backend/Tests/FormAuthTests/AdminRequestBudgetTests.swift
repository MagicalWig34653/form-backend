// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import Vapor
import XCTest
import XCTVapor
@testable import FormAuth
@testable import FormHTTP

/// Admin request budgets: per account (signed in) and per IP (everyone). Real DB, synthetic data.
final class AdminRequestBudgetTests: XCTestCase {
    private let key = try! StaticServerKey(Data(repeating: 5, count: 32))

    private func withGuard(ip: (Int, TimeInterval), account: (Int, TimeInterval), _ body: (DBFixture, AuthGuard, Application) async throws -> Void) async throws {
        try await DBFixture.with { f in
            try HTTPSetup.configure(f.app)
            var cfg = AuthConfig(relyingParty: RelyingParty(rpID: "admin.example.test", origin: "https://admin.example.test"),
                                 clientIP: { $0.headers.first(name: "X-Test-IP") ?? "unknown" })
            cfg.requestBudget = ip
            cfg.accountRequestBudget = account
            let g = AuthGuard(sessions: SessionService(db: f.app.db(.mysql), keys: key),
                              throttles: ThrottleService(db: f.app.db(.mysql), keys: key), config: cfg)
            f.app.get("t") { req async throws -> String in
                try await g.budget(req)
                if req.cookies[SessionService.cookieName] != nil { _ = try await g.currentSession(req) }
                return "ok"
            }
            try await body(f, g, f.app)
        }
    }

    private func signedIn(_ f: DBFixture, _ g: AuthGuard) async throws -> String {
        let account = try await f.account()
        let anon = try await g.sessions.createAnonymous()
        let s = try await g.sessions.rotate(from: anon.session, to: .authenticated, accountID: account, method: "passkey", rightsVersion: 0)
        return "\(SessionService.cookieName)=\(s.token)"
    }

    private func status(_ app: Application, ip: String, cookie: String? = nil) async throws -> (HTTPStatus, String?) {
        var out: (HTTPStatus, String?) = (.ok, nil)
        var h = HTTPHeaders(); h.add(name: "X-Test-IP", value: ip)
        if let cookie { h.add(name: .cookie, value: cookie) }
        try await app.test(.GET, "t", headers: h) { res async throws in out = (res.status, res.headers.first(name: "Retry-After")) }
        return out
    }

    func testAccountBudgetCountsPerAccountNotPerIP() async throws {
        try await withGuard(ip: (1000, 60), account: (3, 60)) { f, g, app in
            let a = try await signedIn(f, g), b = try await signedIn(f, g)
            for _ in 1...3 { let r = try await status(app, ip: "203.0.113.1", cookie: a); XCTAssertEqual(r.0, .ok) }
            let blocked = try await status(app, ip: "203.0.113.1", cookie: a)
            XCTAssertEqual(blocked.0, .tooManyRequests)
            XCTAssertGreaterThanOrEqual(Int(blocked.1 ?? "0") ?? 0, 1)
            // second account behind the same IP is not blocked
            for _ in 1...3 { let r = try await status(app, ip: "203.0.113.1", cookie: b); XCTAssertEqual(r.0, .ok) }
            // anonymous requests are not counted against the account budget
            let anon = try await status(app, ip: "203.0.113.1")
            XCTAssertEqual(anon.0, .ok)
        }
    }

    func testIPBudgetStillAppliesToEveryone() async throws {
        try await withGuard(ip: (4, 60), account: (1000, 60)) { f, g, app in
            let a = try await signedIn(f, g)
            for _ in 1...2 { let r = try await status(app, ip: "203.0.113.2", cookie: a); XCTAssertEqual(r.0, .ok) }
            for _ in 1...2 { let r = try await status(app, ip: "203.0.113.2"); XCTAssertEqual(r.0, .ok) }
            let anon = try await status(app, ip: "203.0.113.2")
            XCTAssertEqual(anon.0, .tooManyRequests)
            let signed = try await status(app, ip: "203.0.113.2", cookie: a)
            XCTAssertEqual(signed.0, .tooManyRequests)
            let other = try await status(app, ip: "203.0.113.3")
            XCTAssertEqual(other.0, .ok)
        }
    }

    func testDefaults() {
        let cfg = AuthConfig(relyingParty: RelyingParty(rpID: "a.test", origin: "https://a.test"))
        XCTAssertEqual(cfg.requestBudget.limit, 600)
        XCTAssertEqual(cfg.accountRequestBudget.limit, 300)
    }
}
