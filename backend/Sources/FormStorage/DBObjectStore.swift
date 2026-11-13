// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import Foundation
import SQLKit

/// Database adapter for objects whose identity and cryptographic metadata already exist in the inventory.
/// Inventory creation and removal of referring rows remain the calling service's responsibility.
public struct DBObjectStore: ObjectStore {
    let sql: SQLDatabase
    let customer: UUID
    let form: UUID
    public init(sql: SQLDatabase, customer: UUID, form: UUID) { self.sql = sql; self.customer = customer; self.form = form }

    private struct Row: Decodable { let ciphertext_sha256: Blob; let byte_count: Int; let state: String }
    private func id(_ key: String) throws -> Blob {
        guard let uuid = UUID(uuidString: key), key == uuid.uuidString.lowercased() else { throw StorageError("invalid_object_key") }
        return DB.bin(uuid)
    }
    private func row(_ key: String, readable: Bool) async throws -> Row? {
        let clause: SQLQueryString = readable ? "AND state = 'ready' AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP(6))" : ""
        return try await sql.raw("SELECT ciphertext_sha256, byte_count, state FROM stored_objects WHERE id = \(bind: try id(key)) AND customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND backend = 'db' \(clause)").first(decoding: Row.self)
    }
    public func put(_ key: String, data: Data) async throws {
        guard data.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        let digest = Blob(Data(SHA256.hash(data: data)))
        guard let existing = try await row(key, readable: false), ["prepared", "failed", "ready"].contains(existing.state) else { throw StorageError("object_unavailable") }
        // Revisions/wrap changes must be coordinated by the inventory service, never inferred from arbitrary bytes here.
        guard existing.ciphertext_sha256.data == digest.data else { throw StorageError("ciphertext_hash_mismatch") }
        // The cell is written in pieces (ChunkedBlob); the first UPDATE resets it, so a failed/partial earlier attempt never leaves a tail.
        try await sql.raw("""
            UPDATE stored_objects SET ciphertext = \(bind: ChunkedBlob.head(data)), ciphertext_sha256 = \(bind: digest), byte_count = \(bind: data.count), state = 'ready'
            WHERE id = \(bind: try id(key)) AND customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND backend = 'db'
              AND state IN ('prepared','failed','ready') AND ciphertext_sha256 = \(bind: digest)
            """).run()
        try await ChunkedBlob.append(data, to: .objectCiphertext, key: try id(key), on: sql)
        // Verified in the database (length and SHA-256), without transferring the cell back.
        struct V: Decodable { let ok: Int }
        guard let current = try await row(key, readable: false), current.state == "ready",
              try await sql.raw("SELECT CAST(OCTET_LENGTH(ciphertext) = \(bind: data.count) AND UNHEX(SHA2(ciphertext, 256)) = \(bind: digest) AS SIGNED) AS ok FROM stored_objects WHERE id = \(bind: try id(key))").first(decoding: V.self)?.ok == 1 else { throw StorageError("object_unavailable") }
    }
    public func get(_ key: String) async throws -> Data {
        guard let r = try await row(key, readable: true), r.byte_count <= ObjectStoreLimits.maxBytes else { throw StorageError("object_unavailable") }
        guard let data = try await ChunkedBlob.read(.objectCiphertext, key: try id(key), on: sql) else { throw StorageError("object_unavailable") }
        guard data.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        guard data.count == r.byte_count, Data(SHA256.hash(data: data)) == r.ciphertext_sha256.data else { throw StorageError("ciphertext_hash_mismatch") }
        return data
    }
    public func delete(_ key: String) async throws {
        try await sql.raw("DELETE FROM stored_objects WHERE id = \(bind: try id(key)) AND customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND backend = 'db'").run()
    }
    public func head(_ key: String) async throws -> Int? { try await row(key, readable: true)?.byte_count }
}
