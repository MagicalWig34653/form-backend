// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
@testable import FormPersistence

final class SplitterTests: XCTestCase {
    func testSplitsAndIgnoresCommentsAndQuotedSemicolons() {
        let s = """
        -- header; with semicolon
        CREATE TABLE a (x INT COMMENT 'a; b -- not a comment'); /* c; d */
        # hash comment;
        INSERT INTO a VALUES ('it''s;ok'), ("q;\\"r");
        CREATE TABLE b (y INT)
        """
        let r = try! SQLStatementSplitter.split(s)
        XCTAssertEqual(r.count, 3)
        XCTAssertTrue(r[0].hasPrefix("CREATE TABLE a") && r[0].contains("'a; b -- not a comment'"))
        XCTAssertTrue(r[1].contains("'it''s;ok'"))
        XCTAssertEqual(r[2], "CREATE TABLE b (y INT)")
    }
    func testUnterminatedCommentOrStringIsAnError() {
        for bad in ["CREATE TABLE a (x INT); /* open", "SELECT 1; /*/", "CREATE TABLE a (x INT COMMENT 'open", "SELECT \"x", "SELECT `x"] {
            XCTAssertThrowsError(try SQLStatementSplitter.split(bad), bad)
        }
        XCTAssertEqual(try SQLStatementSplitter.split("SELECT 1; /* closed */"), ["SELECT 1"])
        XCTAssertEqual(try SQLStatementSplitter.split("SELECT 1 -- trailing comment without newline"), ["SELECT 1"])
    }
    func testRealSchemaStatementCountsAreExact() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
        let script = try String(contentsOfFile: path, encoding: .utf8)
        let stmts = try SQLStatementSplitter.split(script)
        // Independent line-based count of statement openers (the schema has one statement start per line start).
        let lines = script.components(separatedBy: "\n")
        func count(_ prefix: String) -> Int { lines.filter { $0.hasPrefix(prefix) }.count }
        XCTAssertEqual(stmts.filter { $0.hasPrefix("CREATE TABLE ") }.count, count("CREATE TABLE "))
        XCTAssertEqual(stmts.filter { $0.hasPrefix("ALTER TABLE ") }.count, count("ALTER TABLE "))
        XCTAssertEqual(stmts.filter { $0.hasPrefix("INSERT INTO ") }.count, count("INSERT INTO "))
        XCTAssertEqual(count("ALTER TABLE "), 12) // Includes P13 Ads indicator.
        XCTAssertEqual(stmts.filter { $0.hasPrefix("CREATE TRIGGER ") }.count, 11)
        XCTAssertEqual(stmts.filter { $0.hasPrefix("CREATE TABLE ") }.count, 82)  // Includes storage_uploads, legacy draft report, operations journal, account_totp and abuse tables and migration_jobs.
        XCTAssertEqual(stmts.count, count("CREATE TABLE ") + count("ALTER TABLE ") + count("INSERT INTO ") + count("CREATE TRIGGER "))
        // No statement contains a second statement opener at a line start.
        for st in stmts {
            let inner = st.components(separatedBy: "\n").dropFirst().filter { $0.hasPrefix("CREATE TABLE ") || $0.hasPrefix("ALTER TABLE ") }
            XCTAssertTrue(inner.isEmpty, "glued statements")
        }
        XCTAssertEqual(MigrationRunner.checksum(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testCreatedTablesExtraction() {
        XCTAssertEqual(MigrationRunner.createdTables(["CREATE TABLE `a_b` (x INT)", "create table if not exists c (y INT)", "ALTER TABLE a_b ADD z INT"]), ["a_b", "c"])
    }
}
