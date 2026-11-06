// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// RFC 6238, SHA-1, six digits, 30 seconds; one adjacent step for clock drift.
public enum TOTP {
    public static func code(secret: Data, step: Int64, digits: Int = 6) -> String {
        precondition(step >= 0 && (6...8).contains(digits))
        var counter = UInt64(step).bigEndian
        let bytes = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: bytes, using: SymmetricKey(data: secret)))
        let offset = Int(mac[19] & 15)
        let value = mac[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
        return String(format: "%0*u", digits, value % UInt32(pow(10, Double(digits))))
    }
    public static func matchingStep(secret: Data, code: String, at: Date, after: Int64) -> Int64? {
        guard code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let step = Int64(at.timeIntervalSince1970 / 30)
        return [step, step - 1, step + 1].filter { $0 >= 0 && $0 > after }.first {
            constantTimeEqual(Data(Self.code(secret: secret, step: $0).utf8), Data(code.utf8))
        }
    }
    public static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, buffer = 0, result = ""
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[(buffer >> bits) & 31]) }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 { result.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return result
    }
}

/// Row locks serialize setup, verification, replay consumption and the account-wide lockout.
public struct TOTPService: Sendable {
    let db: Database
    let secrets: SecretStore
    let now: @Sendable () -> Date
    public init(db: Database, secrets: SecretStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.secrets = secrets; self.now = now
    }
    struct Row: Decodable {
        let secret_ref: String?; let pending_ref: String?; let pending_until: Date?
        let last_step: Int64; let failures: Int; let locked_until: Date?
    }
    private func row(_ tx: SQLDatabase, _ account: UUID) async throws -> Row {
        struct A: Decodable { let active: Int }
        guard try await tx.raw("SELECT active FROM accounts WHERE id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: A.self)?.active == 1 else { throw Abort(.unauthorized) }
        try await tx.raw("INSERT IGNORE INTO account_totp (account_id) VALUES (\(bind: DB.bin(account)))").run()
        return try await tx.raw("SELECT secret_ref, pending_ref, pending_until, last_step, failures, locked_until FROM account_totp WHERE account_id = \(bind: DB.bin(account)) FOR UPDATE").first(decoding: Row.self)!
    }
    public func enabled(account: UUID) async throws -> Bool {
        struct R: Decodable { let secret_ref: String? }
        return try await (db as! SQLDatabase).raw("SELECT secret_ref FROM account_totp WHERE account_id = \(bind: DB.bin(account))").first(decoding: R.self)?.secret_ref != nil
    }
    public func begin(account: UUID) async throws -> String {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            let r = try await row(tx, account)
            guard r.secret_ref == nil else { throw Abort(.conflict) }
            let secret = Data.random(20)
            let ref = try await secrets.put(secret, on: tx)
            if let old = r.pending_ref { try await tx.raw("DELETE FROM managed_secrets WHERE ref = \(bind: old)").run() }
            try await tx.raw("UPDATE account_totp SET pending_ref = \(bind: ref), pending_until = \(bind: DB.time(now().addingTimeInterval(600))) WHERE account_id = \(bind: DB.bin(account))").run()
            return TOTP.base32(secret)
        }
    }
    /// Failure is returned from the transaction so the counter commits before throwing.
    public func verify(account: UUID, code: String, confirming: Bool = false) async throws {
        let accepted = try await db.transaction { conn -> Bool in
            let tx = conn as! SQLDatabase
            let r = try await row(tx, account)
            let t = now()
            if let until = r.locked_until, until > t { throw RateLimited(retryAfterSeconds: Int(ceil(until.timeIntervalSince(t)))) }
            let ref = confirming ? (r.secret_ref == nil && (r.pending_until ?? .distantPast) > t ? r.pending_ref : nil) : r.secret_ref
            let secret = try await ref.asyncSecret(secrets, tx)
            if let secret, let step = TOTP.matchingStep(secret: secret, code: code, at: t, after: r.last_step) {
                try await tx.raw("UPDATE account_totp SET secret_ref = \(bind: ref), pending_ref = NULL, pending_until = NULL, last_step = \(bind: step), failures = 0, locked_until = NULL WHERE account_id = \(bind: DB.bin(account))").run()
                if confirming { try await audit(tx, account, "account.totp.enable") }
                return true
            }
            let failures = (r.locked_until == nil ? r.failures : 0) + 1
            try await tx.raw("UPDATE account_totp SET failures = \(bind: failures), locked_until = \(bind: failures >= 5 ? DB.time(t.addingTimeInterval(900)) : nil) WHERE account_id = \(bind: DB.bin(account))").run()
            return false
        }
        guard accepted else { throw AuthenticationFailed.translate(SecondFactorError.passwordMismatch) }
    }
    public func remove(account: UUID, password: String) async throws {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            let r = try await row(tx, account)
            struct A: Decodable { let password_hash: String }
            let a = try await tx.raw("SELECT password_hash FROM accounts WHERE id = \(bind: DB.bin(account)) AND active = 1 FOR UPDATE").first(decoding: A.self)
            guard let a, !a.password_hash.isEmpty, await DefaultPasswordVerifier().verify(password: password, hash: a.password_hash) else { throw Abort(.unauthorized) }
            try await tx.raw("DELETE FROM account_totp WHERE account_id = \(bind: DB.bin(account))").run()
            for ref in [r.secret_ref, r.pending_ref].compactMap({ $0 }) { try await tx.raw("DELETE FROM managed_secrets WHERE ref = \(bind: ref)").run() }
            try await tx.raw("UPDATE sessions SET state = 'revoked', revoked_at = \(bind: DB.time(now())) WHERE account_id = \(bind: DB.bin(account)) AND auth_method IN ('password+totp','passkey+totp') AND revoked_at IS NULL").run()
            try await audit(tx, account, "account.totp.remove")
        }
    }
    private func audit(_ tx: SQLDatabase, _ account: UUID, _ action: String) async throws {
        try await tx.raw("INSERT INTO audit_events (id, actor_id, actor_kind, action_code, subject_id, category, occurred_at, safe_details_json) VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), 'human', \(bind: action), \(bind: DB.bin(account)), 'account', \(bind: DB.time(now())), '{}')").run()
    }
}
private extension Optional where Wrapped == String {
    func asyncSecret(_ store: SecretStore, _ tx: SQLDatabase) async throws -> Data? {
        guard let ref = self else { return nil }; return try await store.get(ref, on: tx)
    }
}
