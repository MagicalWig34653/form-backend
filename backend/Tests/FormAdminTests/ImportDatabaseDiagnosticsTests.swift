// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
@testable import FormMigration
import SQLKit
import XCTest

/// The safe metadata of target errors, taken from real MariaDB errors (no constructed driver packets).
final class ImportDatabaseDiagnosticsTests: XCTestCase {
    func need(_ fx: AdminFixture, _ column: String, _ values: [(String, String)]) async throws -> Error {
        let names = values.map { $0.0 }.joined(separator: ","), marks = values.map { "'" + $0.1.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        var failure: Error?
        do { try await fx.sql.raw(SQLQueryString("INSERT INTO diag_t (\(names)) VALUES (\(marks))")).run() } catch { failure = error }
        guard let error = failure else { throw XCTSkip("statement did not fail: \(column)") }
        print("MEASURE-DBERR \(error)")
        return error
    }
    func needNull(_ fx: AdminFixture) async throws -> Error {
        do { try await fx.sql.raw("INSERT INTO diag_t (a) VALUES (NULL)").run() } catch { print("MEASURE-DBERR \(error)"); return error }
        throw XCTSkip("NULL accepted")
    }
    func testRealServerErrorsYieldNumberStateAndObjectNameButNeverTheValue() async throws {
        try await AdminFixture.with { fx in
            let secret = "GEHEIMER-WERT-4711"
            for statement in [
                "CREATE TABLE diag_parent (id INT PRIMARY KEY) ENGINE=InnoDB",
                "CREATE TABLE diag_t (a VARCHAR(100) NOT NULL, b VARCHAR(5) NULL, c INT NULL, p INT NULL, CONSTRAINT uq_diag_a UNIQUE (a), CONSTRAINT fk_diag_p FOREIGN KEY (p) REFERENCES diag_parent(id), CONSTRAINT chk_diag_c CHECK (c > 0)) ENGINE=InnoDB",
            ] { try await fx.sql.raw(SQLQueryString(statement)).run() }
            // Duplicate: the value even imitates the message tail.
            let tricky = "\(secret)' for key 'evil"
            try await fx.sql.raw(SQLQueryString("INSERT INTO diag_t (a) VALUES ('\(tricky.replacingOccurrences(of: "'", with: "''"))')")).run()
            let duplicate = try await need(fx, "dup", [("a", tricky)])
            let notNull = try await needNull(fx)
            let foreign = try await need(fx, "fk", [("a", secret + "-fk"), ("p", "99")])
            let tooLong = try await need(fx, "long", [("a", secret + "-lang"), ("b", "123456789")])
            let check = try await need(fx, "chk", [("a", secret + "-chk"), ("c", "-1")])
            let results = [duplicate, notNull, foreign, tooLong, check].map { DatabaseDiagnostics.classify($0) }
            XCTAssertEqual(results[0]?.code, 1062); XCTAssertEqual(results[0]?.object, "uq_diag_a")
            XCTAssertEqual(results[1]?.code, 1048); XCTAssertEqual(results[1]?.object, "a")
            XCTAssertEqual(results[2]?.code, 1452); XCTAssertEqual(results[2]?.object, "fk_diag_p")
            XCTAssertEqual(results[3]?.code, 1406); XCTAssertEqual(results[3]?.object, "b")
            XCTAssertEqual(results[4]?.code, 4025); XCTAssertEqual(results[4]?.object, "chk_diag_c")
            for result in results { XCTAssertEqual(result?.sqlState.count, 5) }
            let rendered = results.map { "\($0 as Any)" }.joined()
            XCTAssertFalse(rendered.contains(secret), "no value may reach the diagnostics")
            let failure = ImportFailure.databaseAt(table: "datenschluessel", code: 1062, sqlState: "23000", object: "uq_customer_active_key")
            XCTAssertEqual("\(failure)", "migration: database table=datenschluessel code=1062 sqlstate=23000 object=uq_customer_active_key")
            XCTAssertNil(DatabaseDiagnostics.classify(ImportFailure.conflict), "only server errors are classified")
            try await fx.sql.raw("DROP TABLE diag_t").run(); try await fx.sql.raw("DROP TABLE diag_parent").run()
        }
    }
}
