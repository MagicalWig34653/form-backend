// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import XCTest
@testable import FormAdmin

/// Finding 15C5D5E9, normal operation: the ingest writes `stored_objects.ciphertext` as ONE bound value (IngestRoutes INSERT, DBObjectStore.put).
/// This measures what the MariaDB default of 16 MiB does to such a write with the driver in use: each size is written on its own connection
/// with a time limit, and the outcome (ok / error text / timeout) plus the stored size is printed as MEASURE line. Only the size below the limit is asserted.
/// FINDING (measured once on macOS, not kept as a test because MySQLNIO asserts in debug builds on Linux: "Statement not closed"): a bound value of 17
/// and 27 MB at 16 MiB is reported as ok by the driver, yet NO row is stored. Normal operation needs the same max_allowed_packet as the import.
final class PacketLimitNormalOperationTests: XCTestCase {
    private struct V: Decodable { let v: String }
    private actor Box { var value: String?; func set(_ v: String) { value = v } }

    func testBoundWritesAroundTheDefaultPacketLimit() async throws {
        try await AdminFixture.with { f in
            let limit = Int(try await f.sql.raw("SELECT CAST(@@global.max_allowed_packet AS CHAR) AS v").first(decoding: V.self)?.v ?? "0") ?? 0
            try XCTSkipIf(limit != 16_777_216, "test database does not run with the 16 MiB default (\(limit))")
            let table = "packet_cell_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
            try await f.sql.raw("CREATE TABLE \(ident: table) (id INT PRIMARY KEY, ciphertext LONGBLOB NOT NULL)").run()
            var results: [Int: String] = [:], rows: [Int: String] = [:]
            for size in [12_000_000] {
                let box = Box(), sql = f.sql
                Task {
                    do { try await sql.withSession { s in try await s.raw("INSERT INTO \(ident: table) VALUES (\(unsafeRaw: String(size)), \(bind: Blob(Data(repeating: 0x41, count: size))))").run() }; await box.set("ok") }
                    catch { await box.set("error: \(String(describing: error).prefix(140))") }
                }
                var waited = 0
                while await box.value == nil, waited < 40 { try await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
                let outcome = await box.value ?? "timeout after 20 s"
                results[size] = outcome
                let stored = try await f.sql.raw("SELECT CAST(IFNULL(MAX(OCTET_LENGTH(ciphertext)),0) AS CHAR) AS v FROM \(ident: table) WHERE id = \(unsafeRaw: String(size))").first(decoding: V.self)?.v ?? "?"
                rows[size] = stored
                print("MEASURE normal operation, bound \(size) bytes at max_allowed_packet=16 MiB: \(outcome); row stored with \(stored) bytes")
                if outcome != "ok" { break }
            }
            try? await f.sql.raw("DROP TABLE IF EXISTS \(ident: table)").run()
            XCTAssertEqual(results[12_000_000], "ok", "a value below the limit must be written")
            XCTAssertEqual(rows[12_000_000], "12000000")
            // Measured: above the limit the driver reports success, but no row exists (stored 0): the server drops the packet silently.
        }
    }
}
