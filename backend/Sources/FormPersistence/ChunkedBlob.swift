// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLKit

/// MySQLNIO (1.9.x) writes the 3-byte MySQL packet length without splitting and reads a split packet as separate messages, so ONE statement or ONE
/// result row of 16 MiB - 1 (0xFFFFFF) or more is lost or corrupted regardless of `max_allowed_packet` (measured: bound 17 MB -> empty cell, SELECT of a
/// 27 MB cell -> wrong bytes). Large sealed objects are therefore written in pieces (`CONCAT`) and read in pieces (`SUBSTRING`); a statement or row
/// never carries more than `chunk` bytes of payload. The final cell must still fit `max_allowed_packet` on the server (CONCAT result), see docs/BETRIEB.md.
public enum ChunkedBlob {
    /// Payload bytes per statement / result row. Far below 0xFFFFFF, above every ordinary submission (one statement, no extra query).
    public static let chunk = 4 * 1024 * 1024

    public struct Column: Sendable {
        let table: String, key: String, column: String
        public static let objectCiphertext = Column(table: "stored_objects", key: "id", column: "ciphertext")
        public static func custom(table: String, key: String, column: String) -> Column { Column(table: table, key: key, column: column) }
        public static let uploadSpool = Column(table: "storage_uploads", key: "object_id", column: "ciphertext")
    }

    /// First part of `data` for the INSERT/UPDATE that creates the cell; the rest follows with `append`.
    public static func head(_ data: Data) -> Blob { Blob(data.count > chunk ? Data(data.prefix(chunk)) : data) }

    /// Appends everything after the first `chunk` bytes (no-op for small data). Call inside the same transaction as the INSERT/UPDATE of `head`.
    public static func append(_ data: Data, to column: Column, key: Blob, on sql: SQLDatabase) async throws {
        var offset = chunk
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            try await sql.raw("UPDATE \(ident: column.table) SET \(ident: column.column) = CONCAT(\(ident: column.column), \(bind: Blob(Data(data[offset..<end])))) WHERE \(ident: column.key) = \(bind: key)").run()
            offset = end
        }
    }

    /// Reads the whole cell in pieces; nil if the row does not exist or the cell is NULL.
    public static func read(_ column: Column, key: Blob, on sql: SQLDatabase) async throws -> Data? {
        struct N: Decodable { let n: Int? }
        guard let n = try await sql.raw("SELECT CAST(OCTET_LENGTH(\(ident: column.column)) AS SIGNED) AS n FROM \(ident: column.table) WHERE \(ident: column.key) = \(bind: key)").first(decoding: N.self)?.n else { return nil }
        struct P: Decodable { let p: Blob? }
        var out = Data(); out.reserveCapacity(n)
        var offset = 0
        repeat {
            let len = min(chunk, n - offset)
            guard let piece = try await sql.raw("SELECT SUBSTRING(\(ident: column.column), \(literal: offset + 1), \(literal: max(len, 1))) AS p FROM \(ident: column.table) WHERE \(ident: column.key) = \(bind: key)").first(decoding: P.self)?.p else { return nil }
            out.append(piece.data)
            offset += len
        } while offset < n
        return out
    }
}
