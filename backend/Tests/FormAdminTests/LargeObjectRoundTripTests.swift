// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAdmin

/// QA finding "large upload 500": MySQLNIO cannot carry a statement or result row of 16 MiB - 1 or more (the 3-byte packet length is neither split on
/// write nor joined on read), whatever `max_allowed_packet` says. `ChunkedBlob` writes (CONCAT) and reads (SUBSTRING) in pieces of 4 MiB.
/// Needs a database with a packet limit above ~60 MiB (P3B_DB_ARGS=--max-allowed-packet=67108864 backend/integration-test.sh --filter LargeObjectRoundTrip).
final class LargeObjectRoundTripTests: XCTestCase {
    private struct V: Decodable { let v: String }
    private struct B: Decodable { let ciphertext: Blob }

    private func pattern(_ size: Int) -> Data {
        var d = Data(count: size); for i in stride(from: 0, to: size, by: 4099) { d[i] = UInt8(truncatingIfNeeded: i / 4099) }
        return d
    }

    func testChunkedWriteAndReadRoundTripBeyondTheDriverPacketLimit() async throws {
        try await AdminFixture.with { f in
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
            let table = "big_rt_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
            try await f.sql.raw("CREATE TABLE \(ident: table) (id BINARY(16) PRIMARY KEY, ciphertext LONGBLOB NULL)").run()
            let column = ChunkedBlob.Column.custom(table: table, key: "id", column: "ciphertext")
            for size in [1_000, 4 * 1024 * 1024, 4 * 1024 * 1024 + 1, 12_000_000, 14_000_000, 16_777_215, 16_777_216, 17_000_000, 27_000_000] {
                let d = pattern(size), key = DB.bin(UUID())
                try await f.sql.raw("INSERT INTO \(ident: table) (id, ciphertext) VALUES (\(bind: key), \(bind: ChunkedBlob.head(d)))").run()
                try await ChunkedBlob.append(d, to: column, key: key, on: f.sql)
                let stored = try await f.sql.raw("SELECT UNHEX(SHA2(ciphertext, 256)) AS ciphertext FROM \(ident: table) WHERE id = \(bind: key)").first(decoding: B.self)?.ciphertext.data
                XCTAssertEqual(stored, Data(SHA256.hash(data: d)), "stored \(size)")
                let back = try await ChunkedBlob.read(column, key: key, on: f.sql)
                XCTAssertEqual(back?.count, size, "read length \(size)")
                XCTAssertEqual(back.map { Data(SHA256.hash(data: $0)) }, Data(SHA256.hash(data: d)), "read hash \(size)")
            }
            try? await f.sql.raw("DROP TABLE IF EXISTS \(ident: table)").run()
        }
    }

    /// Documents WHY chunking exists (a single bound value above 0xFFFFFF is lost). Informational: it only prints, so a fixed driver does not break the build.
    func testMeasureDriverLimitWithoutChunking() async throws {
        try await AdminFixture.with { f in
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit < 60_000_000, "needs max_allowed_packet >= 64 MiB (got \(limit))")
            let table = "big_raw_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
            try await f.sql.raw("CREATE TABLE \(ident: table) (id INT PRIMARY KEY, ciphertext LONGBLOB NOT NULL)").run()
            for size in [14_000_000, 17_000_000] {
                let d = pattern(size)
                var outcome = "ok"
                do { try await f.sql.raw("INSERT INTO \(ident: table) VALUES (\(unsafeRaw: String(size)), \(bind: Blob(d)))").run() } catch { outcome = "error \(DB.logDescription(error))" }
                let n = try await f.sql.raw("SELECT CAST(IFNULL(MAX(OCTET_LENGTH(ciphertext)),0) AS CHAR) AS v FROM \(ident: table) WHERE id = \(unsafeRaw: String(size))").first(decoding: V.self)?.v ?? "?"
                print("MEASURE unchunked bound value \(size) bytes at max_allowed_packet=\(limit): \(outcome), stored \(n) bytes")
            }
            try? await f.sql.raw("DROP TABLE IF EXISTS \(ident: table)").run()
        }
    }
}
