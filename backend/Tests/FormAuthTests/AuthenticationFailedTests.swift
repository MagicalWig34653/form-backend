// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import XCTest
import XCTVapor
@testable import FormAuth
@testable import FormHTTP

final class AuthenticationFailedTests: XCTestCase {
        private let allCauses: [Error] = [
        PasskeyError.clientDataInvalid,
        PasskeyError.wrongType,
        PasskeyError.challengeMismatch,
        PasskeyError.originMismatch,
        PasskeyError.rpIdHashMismatch,
        PasskeyError.userNotPresent,
        PasskeyError.userNotVerified,
        PasskeyError.signatureInvalid,
        PasskeyError.authenticatorDataInvalid,
        PasskeyError.counterRegression,
        PasskeyError.unsupportedKey,
        PasskeyError.userHandleMismatch,
        PasskeyError.unknownCredential,
        PasskeyError.challengeInvalid,
        PasskeyError.authenticationFailed,
        SecondFactorError.noSession,
        SecondFactorError.wrongState,
        SecondFactorError.unknownAccount,
        SecondFactorError.noPasswordHash,
        SecondFactorError.passwordMismatch,
        SecondFactorError.accountInactive,
    ]

    /// Every internal cause yields byte-identical status, body (except requestId) and headers (except X-Request-Id).
    func testAllCausesAreIndistinguishableOverHTTP() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.middleware = .init()
        app.middleware.use(ProblemMiddleware())
        for (i, cause) in allCauses.enumerated() {
            app.get("fail", "\(i)") { _ -> Response in throw AuthenticationFailed.translate(cause) }
        }
        var seen: Set<String> = []
        for i in allCauses.indices {
            try await app.test(.GET, "fail/\(i)") { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
                var p = try JSONDecoder().decode(Problem.self, from: Data(buffer: res.body))
                XCTAssertEqual(p.code, "authentication_failed")
                p = Problem(code: p.code, message: p.message, requestId: "")
                var headers = res.headers
                headers.remove(name: "X-Request-Id")
                XCTAssertNil(headers.first(name: "Retry-After"))
                XCTAssertNil(headers.first(name: "Set-Cookie"))
                seen.insert("\(res.status.code)|\(p.code)|\(p.message)|\(headers.map { "\($0.name.lowercased()):\($0.value)" }.sorted())")
            }
        }
        XCTAssertEqual(seen.count, 1, "responses differ between causes: \(seen)")
    }

    func testAuditReasonDiffersButIsNotPublic() {
        let a = AuthenticationFailed.translate(PasskeyError.unknownCredential)
        let b = AuthenticationFailed.translate(PasskeyError.signatureInvalid)
        XCTAssertNotEqual(a.auditReason, b.auditReason)
        XCTAssertFalse(a.message.contains("unknown"))
    }

    func testRateLimitedCarriesRetryAfterAndMinimumOne() async throws {
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        app.middleware = .init()
        app.middleware.use(ProblemMiddleware())
        app.get("rl") { _ -> Response in throw RateLimited(retryAfterSeconds: 0) }
        app.get("na") { _ -> Response in throw ServiceUnavailable(retryAfterSeconds: 5) }
        try await app.test(.GET, "rl") { res async throws in
            XCTAssertEqual(res.status, .tooManyRequests)
            XCTAssertEqual(res.headers.first(name: "Retry-After"), "1")
            XCTAssertEqual(try JSONDecoder().decode(Problem.self, from: Data(buffer: res.body)).code, "rate_limited")
        }
        try await app.test(.GET, "na") { res async throws in
            XCTAssertEqual(res.status, .serviceUnavailable)
            XCTAssertEqual(res.headers.first(name: "Retry-After"), "5")
        }
    }
}
