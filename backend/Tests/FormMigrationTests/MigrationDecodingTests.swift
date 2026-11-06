// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
@testable import FormMigration

final class MigrationDecodingTests: XCTestCase {
    func testMigrationUnknownConfigurationValuesRequireMappingReview() {
        let known = LegacyRow(values:["ID":"2D32", "name":"74657374", "cloudflareKeys":"736563726574"],table:"formulare")
        XCTAssertFalse(known.hasUnmappedConfigurationValues)
        XCTAssertFalse(LegacyRow(values:["extra":nil, "empty":""],table:"formulare").hasUnmappedConfigurationValues)
        // Even zero and binary data are populated; no decoding or plaintext logging is needed.
        for value in ["30", "00FF", "736563726574"] {
            XCTAssertTrue(LegacyRow(values:["extra":value],table:"formulare").hasUnmappedConfigurationValues)
        }
    }

    func testMigrationHexByteDecodingPreservesTextBinaryAndNull() throws {
        let row = try LegacyRow.decode(#"{"ID":"31","time":"31373030303030303030","flag":"30","binary":"00FF80","optional":null,"empty":""}"#,table:"anfragen")
        XCTAssertEqual(try row.required("ID"),"1")
        XCTAssertEqual(try row.required("time"),"1700000000")
        XCTAssertEqual(try row.required("flag"),"0")
        XCTAssertEqual(try row.bytes("binary"),Data([0,255,128]))
        XCTAssertNil(try row.text("optional"))
        XCTAssertEqual(try row.text("empty"),"")
        XCTAssertEqual(try unhex("aAbBcC"),Data([170,187,204]))
    }

    func testMigrationUUIDTextAcceptsBothCasesWithoutTreatingBinaryAsText() throws {
        let uuid = "aabbccdd-1111-4111-8111-aabbccddeeff"
        let lower = LegacyRow(values:["UUID":hex(Data(uuid.utf8))],table:"formulare")
        let upper = LegacyRow(values:["UUID":hex(Data(uuid.uppercased().utf8))],table:"formulare")
        XCTAssertEqual(try lower.uuid("UUID"),try upper.uuid("UUID"))
        // BINARY(16) is explicitly a byte field, never implicitly reinterpreted as UUID text.
        XCTAssertEqual(try lower.required("UUID"),uuid)
    }

    func testMigrationDiagnosticsContainOnlySchemaContext() throws {
        let cases: [(LegacyRow,String,SourceFailureReason)] = [
            (LegacyRow(values:["ID":"1"],table:"formulare"),"ID",.invalidHex),
            (LegacyRow(values:["ID":"ZZ"],table:"formulare"),"ID",.invalidHex),
            (LegacyRow(values:["data":"FF"],table:"anfragen"),"data",.invalidUTF8),
            (LegacyRow(values:["UUID":nil],table:"formulare"),"UUID",.missingValue),
            (LegacyRow(values:[:],table:"formulare"),"ID",.missingColumn)
        ]
        for (row,column,reason) in cases {
            XCTAssertThrowsError(try row.required(column)) { error in
                guard case let ImportFailure.invalidSourceAt(table,actualColumn,actualReason) = error else { return XCTFail("Expected schema diagnostic") }
                XCTAssertEqual(table,row.table); XCTAssertEqual(actualColumn,column); XCTAssertEqual(actualReason,reason)
                XCTAssertEqual(String(describing:error),"migration: invalidSource table=\(row.table) column=\(column) reason=\(reason.rawValue)")
            }
        }
        let privateValue = "must-never-be-printed"
        let row = LegacyRow(values:["UUID":hex(Data(privateValue.utf8))],table:"formulare")
        XCTAssertThrowsError(try row.uuid("UUID")) { error in
            XCTAssertEqual(String(describing:error),"migration: invalidSource table=formulare column=UUID reason=invalidUUID")
            XCTAssertFalse(String(describing:error).contains(privateValue))
        }
        XCTAssertThrowsError(try LegacyRow.decode(#"{"SMTPPassword":123}"#,table:"outgoingMailServer")) { error in
            XCTAssertEqual(String(describing:error),"migration: invalidSource table=outgoingMailServer column=SMTPPassword reason=invalidProjection")
        }
        XCTAssertThrowsError(try ident(privateValue)) { error in XCTAssertFalse(String(describing:error).contains(privateValue)) }
        let untrusted = ImportFailure.invalidSourceAt(table:privateValue,column:privateValue,reason:.invalidIdentifier)
        XCTAssertFalse(untrusted.description.contains(privateValue))
    }
}
