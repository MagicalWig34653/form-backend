// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// The inventory is authoritative. A durable ciphertext-only upload spool bridges SQL and remote storage.
public struct StorageService: Sendable {
    public let db: Database
    let secrets: SecretStore
    let allowedNets: [CIDR]
    public typealias AdapterFactory = @Sendable (String, [String: Any], String, [CIDR]) throws -> any ObjectStore
    let adapterFactory: AdapterFactory
    public init(db: Database, secrets: SecretStore, allowedNets: [CIDR] = [], adapterFactory: @escaping AdapterFactory = { try StorageService.adapter(kind: $0, config: $1, credential: $2, allowedNets: $3) }) {
        self.db = db; self.secrets = secrets; self.allowedNets = allowedNets; self.adapterFactory = adapterFactory
    }
    public struct Policy: Codable, Sendable {
        public var connectionId: UUID?
        public var data: Bool
        public var attachmentThreshold: Int?
        public init(connectionId: UUID? = nil, data: Bool = false, attachmentThreshold: Int? = nil) { self.connectionId = connectionId; self.data = data; self.attachmentThreshold = attachmentThreshold }
    }
    public func policy(customer: UUID, form: UUID?, sql: SQLDatabase) async throws -> Policy {
        struct R: Decodable { let safe_value_json: String }
        let scopes = form.map { ["form:\($0.uuidString.lowercased())"] } ?? []
        for scope in scopes + ["customer:\(customer.uuidString.lowercased())"] {
            if let r = try await sql.raw("SELECT safe_value_json FROM settings WHERE scope_key = \(bind: scope) AND setting_key = 'storage.policy'").first(decoding: R.self) {
                return try JSONDecoder().decode(Policy.self, from: Data(r.safe_value_json.utf8))
            }
        }
        return Policy()
    }
    public func store(customer: UUID, connection: UUID, sql: SQLDatabase) async throws -> (String, any ObjectStore) {
        struct R: Decodable { let kind: String; let safe_config_json: String; let credential_ref: String? }
        guard let r = try await sql.raw("SELECT c.kind, c.safe_config_json, c.credential_ref FROM connections c JOIN customer_connections cc ON cc.connection_id = c.id WHERE cc.customer_id = \(bind: DB.bin(customer)) AND c.id = \(bind: DB.bin(connection)) AND c.enabled = 1 AND c.kind IN ('s3','sftp')").first(decoding: R.self),
              let ref = r.credential_ref, let secret = try await secrets.get(ref), let credential = String(data: secret, encoding: .utf8),
              let config = try JSONSerialization.jsonObject(with: Data(r.safe_config_json.utf8)) as? [String: Any] else { throw StorageError("connection_unavailable") }
        return (r.kind, try adapterFactory(r.kind, config, credential, allowedNets))
    }
    public static func adapter(kind: String, config: [String: Any], credential: String, allowedNets: [CIDR]) throws -> any ObjectStore {
        switch kind {
        case "s3": return try S3ObjectStore(config: config, credential: credential, allowedNets: allowedNets)
        case "sftp": return try SFTPObjectStore(config: config, credential: credential, allowedNets: allowedNets)
        default: throw StorageError("connection_invalid")
        }
    }
    /// Called in the ingest transaction; never writes remotely before a durable inventory exists.
    public func insert(sql: SQLDatabase, customer: UUID, form: UUID, submission: UUID, role: String, ordinal: Int, wire: Data, kid: String, payloadHash: Data, originalBytes: Int) async throws {
        guard wire.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        let policy = try await policy(customer: customer, form: form, sql: sql)
        let external = policy.connectionId != nil && ((role == "data" && policy.data) || (role == "attachment" && policy.attachmentThreshold.map { originalBytes > $0 } == true))
        let id = UUID()
        var backend = "db"
        if external { backend = try await store(customer: customer, connection: policy.connectionId!, sql: sql).0 }
        let key = external ? Blob(Data((customer.uuidString.lowercased() + "/" + id.uuidString.lowercased() + "/0").utf8)) : nil
        try await sql.raw("""
            INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, connection_id, object_key, ciphertext,
              packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
            VALUES (\(bind: DB.bin(id)), \(bind: DB.bin(customer)), \(bind: DB.bin(form)), \(bind: DB.bin(submission)), \(bind: role), \(bind: ordinal), 0,
              \(bind: backend), \(bind: external ? policy.connectionId.map(DB.bin) : nil), \(bind: key), \(bind: external ? nil : ChunkedBlob.head(wire)), 'KUBUS-AEAD:2', 'hpke', \(bind: kid), 'raw',
              \(bind: Blob(Data(SHA256.hash(data: wire)))), \(bind: Blob(payloadHash)), \(bind: wire.count), \(bind: external ? "prepared" : "ready"))
            """).run()
        if external {
            try await sql.raw("INSERT INTO storage_uploads (object_id, ciphertext, created_at) VALUES (\(bind: DB.bin(id)), \(bind: ChunkedBlob.head(wire)), \(bind: DB.time(Date())))").run()
            try await ChunkedBlob.append(wire, to: .uploadSpool, key: DB.bin(id), on: sql)
        } else {
            try await ChunkedBlob.append(wire, to: .objectCiphertext, key: DB.bin(id), on: sql)
        }
    }
    public struct ObjectRow: Decodable {
        public let id: Blob, customer_id: Blob, form_id: Blob
        public let backend: String, state: String
        public let connection_id: Blob?, object_key: Blob?
        public let ciphertext_sha256: Blob
        public let byte_count: Int
        /// Inventory columns only. NEVER `SELECT *` here: the ciphertext cell can be 20+ MB (driver limit, see ChunkedBlob) and is not needed to inspect, lock or delete an object.
        public static let columns: SQLQueryString = "id, customer_id, form_id, backend, state, connection_id, object_key, ciphertext_sha256, byte_count"
    }
    public func read(sql: SQLDatabase, customer: UUID, form: UUID, object: Blob) async throws -> Data {
        guard let row = try await sql.raw("SELECT \(ObjectRow.columns) FROM stored_objects WHERE id = \(bind: object) AND customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND state = 'ready' AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP(6))").first(decoding: ObjectRow.self) else { throw StorageError("object_unavailable") }
        let bytes: Data
        if row.backend == "db", let id = DB.uuid(row.id.data) { bytes = try await DBObjectStore(sql: sql, customer: customer, form: form).get(id.uuidString.lowercased()) }
        else {
            guard let connection = row.connection_id.flatMap({ DB.uuid($0.data) }), let key = row.object_key.flatMap({ String(data: $0.data, encoding: .utf8) }) else { throw StorageError("inventory_invalid") }
            bytes = try await store(customer: customer, connection: connection, sql: sql).1.get(key)
        }
        guard bytes.count == row.byte_count, Data(SHA256.hash(data: bytes)) == row.ciphertext_sha256.data else { throw StorageError("ciphertext_hash_mismatch") }
        return bytes
    }
    /// A row/submission lock serializes upload and deletion. Failed writes retain their spool for retry.
    public func flush(submission: UUID? = nil) async throws {
        let sql = db as! SQLDatabase
        struct R: Decodable { let id: Blob; let submission_id: Blob? }
        let clause: SQLQueryString = submission.map { "AND o.submission_id = \(bind: DB.bin($0))" } ?? ""
        let rows = try await sql.raw("SELECT o.id, o.submission_id FROM stored_objects o JOIN storage_uploads u ON u.object_id = o.id WHERE o.state IN ('prepared','failed') \(clause) ORDER BY u.created_at LIMIT 100").all(decoding: R.self)
        for row in rows {
            let failed = try await db.transaction { conn -> Bool in
                let tx = conn as! SQLDatabase
                if let s = row.submission_id { _ = try await tx.raw("SELECT id FROM submissions WHERE id = \(bind: s) FOR UPDATE").all() }
                guard let o = try await tx.raw("SELECT \(ObjectRow.columns) FROM stored_objects WHERE id = \(bind: row.id) AND state IN ('prepared','failed') FOR UPDATE").first(decoding: ObjectRow.self),
                      let customer = DB.uuid(o.customer_id.data), let connection = o.connection_id.flatMap({ DB.uuid($0.data) }), let key = o.object_key.flatMap({ String(data: $0.data, encoding: .utf8) }) else { return false }
                guard let spooled = try await ChunkedBlob.read(.uploadSpool, key: row.id, on: tx) else { return false }
                do {
                    guard Data(SHA256.hash(data: spooled)) == o.ciphertext_sha256.data else { throw StorageError("ciphertext_hash_mismatch") }
                    try await store(customer: customer, connection: connection, sql: tx).1.put(key, data: spooled)
                    try await tx.raw("UPDATE stored_objects SET state = 'ready' WHERE id = \(bind: row.id)").run()
                    try await tx.raw("DELETE FROM storage_uploads WHERE object_id = \(bind: row.id)").run()
                } catch {
                    try await tx.raw("UPDATE stored_objects SET state = 'failed' WHERE id = \(bind: row.id)").run()
                    try await tx.raw("UPDATE storage_uploads SET created_at = \(bind: DB.time(Date())) WHERE object_id = \(bind: row.id)").run()
                    return true
                }
                return false
            }
            if failed && submission != nil { throw StorageError("upload_failed") }
        }
    }
    public func deleteRemote(_ row: ObjectRow, sql: SQLDatabase) async throws {
        guard row.backend != "db" else { return }
        guard let customer = DB.uuid(row.customer_id.data), let connection = row.connection_id.flatMap({ DB.uuid($0.data) }), let key = row.object_key.flatMap({ String(data: $0.data, encoding: .utf8) }) else { throw StorageError("inventory_invalid") }
        try await store(customer: customer, connection: connection, sql: sql).1.delete(key)
    }
}

public struct StorageServiceKey: StorageKey { public typealias Value = StorageService }

extension StorageService {
    /// No spool means an interrupted/legacy write cannot be resumed. Remove its remote copy, retaining the failed
    /// inventory reference (and key generation) until an explicit submission deletion confirms the complete graph.
    public func cleanOrphans() async throws {
        let sql = db as! SQLDatabase
        struct R: Decodable { let id: Blob; let submission_id: Blob? }
        let rows = try await sql.raw("SELECT o.id, o.submission_id FROM stored_objects o LEFT JOIN storage_uploads u ON u.object_id = o.id WHERE o.backend <> 'db' AND o.state = 'prepared' AND u.object_id IS NULL LIMIT 100").all(decoding: R.self)
        for r in rows {
            try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                if let s = r.submission_id { _ = try await tx.raw("SELECT id FROM submissions WHERE id = \(bind: s) FOR UPDATE").all() }
                guard let row = try await tx.raw("SELECT \(ObjectRow.columns) FROM stored_objects WHERE id = \(bind: r.id) AND state = 'prepared' FOR UPDATE").first(decoding: ObjectRow.self) else { return }
                try await deleteRemote(row, sql: tx)
                try await tx.raw("UPDATE stored_objects SET state = 'failed' WHERE id = \(bind: r.id)").run()
            }
        }
    }
}
