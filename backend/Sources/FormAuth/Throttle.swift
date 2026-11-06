// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormPersistence
import Foundation
import SQLKit

public enum ThrottleScope: String, Sendable { case account, ip, totp, adminRoute = "admin-route" }

/// Failure counter with lockout and optional backoff (anmeldung.md, thresholds VORGESCHLAGEN).
public struct FailurePolicy: Sendable {
    public let limit: Int
    public let window: TimeInterval
    public let lock: TimeInterval
    /// Backoff from the third failure: 1 s, 2 s, 4 s ... at most 60 s, until the limit locks for `lock`.
    public let backoff: Bool
    public init(limit: Int, window: TimeInterval, lock: TimeInterval, backoff: Bool) {
        self.limit = limit; self.window = window; self.lock = lock; self.backoff = backoff
    }
    public static let passwordPerAccount = FailurePolicy(limit: 5, window: 900, lock: 900, backoff: true)
    public static let passwordPerIP = FailurePolicy(limit: 30, window: 900, lock: 900, backoff: false)
    public static let secondFactor = FailurePolicy(limit: 5, window: 900, lock: 900, backoff: true)
}

/// Throttles in `auth_throttles`; subjects are stored only as HMAC under the server key (unknown credentials/accounts
/// are throttled the same way as known ones, so a 429 is no existence oracle). No blocking sleeps.
public struct ThrottleService: Sendable {
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let keys: any ServerKeyProvider
    let now: @Sendable () -> Date

    public init(db: Database, keys: any ServerKeyProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.keys = keys; self.now = now
    }

    func subject(_ scope: ThrottleScope, _ key: String) async throws -> Blob {
        let k = KeyPurpose.throttle.derive(from: try await keys.serverKey())
        return Blob(Data(HMAC<SHA256>.authenticationCode(for: Data("\(scope.rawValue)\u{0}\(key)".utf8), using: k)))
    }

    /// Throws `RateLimited` while a lock is active. Does not extend the lock.
    public func ensureNotLocked(_ scope: ThrottleScope, _ key: String) async throws {
        struct R: Decodable { let locked_until: Date? }
        let s = try await subject(scope, key)
        let t = now()
        let row = try await sql.raw("""
            SELECT MAX(locked_until) AS locked_until FROM auth_throttles
            WHERE scope = \(bind: scope.rawValue) AND subject_hmac = \(bind: s) AND locked_until > \(bind: DB.time(t))
            """).first(decoding: R.self)
        if let until = row?.locked_until { throw RateLimited(retryAfterSeconds: Int(until.timeIntervalSince(t).rounded(.up))) }
    }

    /// Records one failure. At the limit the subject is locked for `policy.lock`; before that backoff applies.
    public func recordFailure(_ scope: ThrottleScope, _ key: String, policy: FailurePolicy) async throws {
        let s = try await subject(scope, key)
        let t = now()
        let start = Date(timeIntervalSince1970: floor(t.timeIntervalSince1970 / policy.window) * policy.window)
        let expires = start.addingTimeInterval(policy.window + policy.lock)
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            try await tx.raw("""
                INSERT INTO auth_throttles (scope, subject_hmac, window_start, failures, locked_until, expires_at)
                VALUES (\(bind: scope.rawValue), \(bind: s), \(bind: DB.time(start)), 1, NULL, \(bind: DB.time(expires)))
                ON DUPLICATE KEY UPDATE failures = failures + 1
                """).run()
            struct C: Decodable { let failures: Int }
            let n = try await tx.raw("""
                SELECT failures FROM auth_throttles WHERE scope = \(bind: scope.rawValue) AND subject_hmac = \(bind: s) AND window_start = \(bind: DB.time(start)) FOR UPDATE
                """).first(decoding: C.self)?.failures ?? 1
            var lockFor: TimeInterval? = nil
            if n >= policy.limit { lockFor = policy.lock }
            else if policy.backoff, n >= 3 { lockFor = min(60, pow(2, Double(n - 3))) }
            if let lockFor {
                // The larger current lock wins; a call during a lock never shortens it.
                try await tx.raw("""
                    UPDATE auth_throttles SET locked_until = GREATEST(COALESCE(locked_until, '1000-01-01'), \(bind: DB.time(t.addingTimeInterval(lockFor))))
                    WHERE scope = \(bind: scope.rawValue) AND subject_hmac = \(bind: s) AND window_start = \(bind: DB.time(start))
                    """).run()
            }
        }
    }

    /// Success clears only the account failure history, never IP budgets or request limits.
    public func clear(_ scope: ThrottleScope, _ key: String) async throws {
        let s = try await subject(scope, key)
        try await sql.raw("DELETE FROM auth_throttles WHERE scope = \(bind: scope.rawValue) AND subject_hmac = \(bind: s)").run()
    }

    /// Request budget: every call counts once in a fixed window; over the limit -> `RateLimited` until the window ends.
    public func consume(_ scope: ThrottleScope, _ key: String, limit: Int, window: TimeInterval) async throws {
        let s = try await subject(scope, key)
        let t = now()
        let start = Date(timeIntervalSince1970: floor(t.timeIntervalSince1970 / window) * window)
        let end = start.addingTimeInterval(window)
        try await sql.raw("""
            INSERT INTO auth_throttles (scope, subject_hmac, window_start, failures, locked_until, expires_at)
            VALUES (\(bind: scope.rawValue), \(bind: s), \(bind: DB.time(start)), 1, NULL, \(bind: DB.time(end)))
            ON DUPLICATE KEY UPDATE failures = failures + 1
            """).run()
        struct C: Decodable { let failures: Int }
        let n = try await sql.raw("SELECT failures FROM auth_throttles WHERE scope = \(bind: scope.rawValue) AND subject_hmac = \(bind: s) AND window_start = \(bind: DB.time(start))").first(decoding: C.self)?.failures ?? 1
        if n > limit { throw RateLimited(retryAfterSeconds: Int(end.timeIntervalSince(t).rounded(.up))) }
    }
}
