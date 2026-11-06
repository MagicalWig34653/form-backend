// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormPersistence
import Foundation
import SQLKit

/// Secrets referenced by `secret_ref` columns (ADR 0006 Nr. 6, D9): AES-256-GCM in `managed_secrets`, key derived with HKDF from
/// the operating-environment server key, the reference bound as AAD (a swapped row cannot be opened). Plaintext only in memory.
public struct SecretStore: Sendable {
    public static let prefix = "s1:"
    let db: Database
    var sql: SQLDatabase { db as! SQLDatabase }
    let keys: any ServerKeyProvider
    let now: @Sendable () -> Date

    public init(db: Database, keys: any ServerKeyProvider, now: @escaping @Sendable () -> Date = { Date() }) { self.db = db; self.keys = keys; self.now = now }

    public enum Failure: Error, Equatable { case badReference, tooLong }

    public static func validRef(_ ref: String) -> Bool {
        ref.hasPrefix(prefix) && UUID(uuidString: String(ref.dropFirst(prefix.count))).map { ref == prefix + $0.uuidString.lowercased() } ?? false
    }

    private func key() async throws -> SymmetricKey { KeyPurpose.secrets.derive(from: try await keys.serverKey()) }

    /// Stores a new secret (in the caller's transaction when `on` is given) and returns its reference.
    @discardableResult
    public func put(_ secret: Data, on database: SQLDatabase? = nil) async throws -> String {
        guard secret.count <= 200 else { throw Failure.tooLong }
        let ref = Self.prefix + UUID().uuidString.lowercased()
        let box = try AES.GCM.seal(secret, using: try await key(), authenticating: Data(ref.utf8))
        try await (database ?? sql).raw("""
            INSERT INTO managed_secrets (ref, ciphertext, key_version, created_at)
            VALUES (\(bind: ref), \(bind: Blob(box.combined!)), 1, \(bind: DB.time(now())))
            """).run()
        return ref
    }

    /// nil when the reference is unknown or the entry cannot be authenticated (wrong key, tampered or swapped row).
    public func get(_ ref: String, on database: SQLDatabase? = nil) async throws -> Data? {
        guard Self.validRef(ref) else { return nil }
        struct R: Decodable { let ciphertext: Blob }
        guard let r = try await (database ?? sql).raw("SELECT ciphertext FROM managed_secrets WHERE ref = \(bind: ref)").first(decoding: R.self),
              let box = try? AES.GCM.SealedBox(combined: r.ciphertext.data) else { return nil }
        return try? AES.GCM.open(box, using: try await key(), authenticating: Data(ref.utf8))
    }
    /// Offline maintenance: retain the old provider until all rows have been rewrapped successfully.
    /// Runs atomically; no plaintext leaves memory and references remain stable.
    public func reencrypt(from previous: SecretStore) async throws {
        try await db.transaction { conn in
            let tx = conn as! SQLDatabase
            struct R: Decodable { let ref: String }
            let rows = try await tx.raw("SELECT ref FROM managed_secrets ORDER BY ref FOR UPDATE").all(decoding: R.self)
            for r in rows {
                guard let plain = try await previous.get(r.ref, on: tx) else { throw Failure.badReference }
                let box = try AES.GCM.seal(plain, using: try await key(), authenticating: Data(r.ref.utf8))
                try await tx.raw("UPDATE managed_secrets SET ciphertext = \(bind: Blob(box.combined!)), key_version = key_version + 1 WHERE ref = \(bind: r.ref)").run()
            }
        }
    }

}
