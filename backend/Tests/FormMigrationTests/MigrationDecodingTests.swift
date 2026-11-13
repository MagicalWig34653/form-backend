// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto
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

    // MARK: CLI Funde (Karte A5F93B32): Plan-Decoding, Digest-Stabilitaet

    static let fullPlanJSON = #"{"connectionCustomers":{"44444444-4444-4444-8444-444444444441":["0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c"]},"customers":{"0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c":"CLI Test GmbH"},"dumpSHA256":"0000000000000000000000000000000000000000000000000000000000000001","formCustomers":{"11111111-1111-4111-8111-111111111111":"0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c"},"keyCustomers":{"a6077815bba8b14c":"0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c"},"keyGenerationNumbers":{"a6077815bba8b14c":1},"namespace":"cli-e2e","statisticsPublicKeys":{"0c0c0c0c-0c0c-4c0c-8c0c-0c0c0c0c0c0c":"AAAA"},"statisticsReview":"ref"}"#

    /// The plan is part of the source HMAC and of the run identity (ADR 0014): a tolerant decoder must not change the canonical JSON
    /// of a plan that decodes today. The pinned digest was computed with the decoder BEFORE the change.
    func testPlanDigestOfExistingPlanIsUnchanged() throws {
        let plan = try JSONDecoder().decode(ImportPlan.self,from:Data(Self.fullPlanJSON.utf8))
        XCTAssertEqual(try json(plan),Self.fullPlanJSON)
        XCTAssertEqual(hex(Data(SHA256.hash(data:Data(try json(plan).utf8)))),"5848bf9aa476b747e6366a4165e5ab112dfb7d4a2a99f8065a057881f1bf0207")
        let tolerant = try ImportPlan.decode(Data(Self.fullPlanJSON.utf8))
        XCTAssertEqual(try json(tolerant),Self.fullPlanJSON)
    }

    func testPlanDecodingToleratesMissingOptionalFieldsWithInitializerDefaults() throws {
        let minimal = #"{"namespace":"n","dumpSHA256":"00","customers":{},"formCustomers":{}}"#
        let plan = try ImportPlan.decode(Data(minimal.utf8))
        XCTAssertEqual(plan.connectionCustomers,[:]); XCTAssertEqual(plan.keyCustomers,[:]); XCTAssertEqual(plan.keyGenerationNumbers,[:])
        XCTAssertNil(plan.statisticsReview); XCTAssertEqual(plan.statisticsPublicKeys,[:])
        let reference = ImportPlan(namespace:"n",dumpSHA256:"00",customers:[:],formCustomers:[:])
        XCTAssertEqual(try json(plan),try json(reference))
    }

    func testPlanDecodingKeepsSecurityRelevantFieldsRequiredAndNamesOnlyTheKey() {
        let secret = "must-never-be-printed"
        let cases: [(String,String)] = [
            (#"{"dumpSHA256":"00","customers":{},"formCustomers":{}}"#,"namespace"),
            (#"{"namespace":"n","customers":{},"formCustomers":{}}"#,"dumpSHA256"),
            (#"{"namespace":"n","dumpSHA256":"00","formCustomers":{}}"#,"customers"),
            (#"{"namespace":"n","dumpSHA256":"00","customers":{}}"#,"formCustomers"),
            (#"{"namespace":"\#(secret)","dumpSHA256":"00","customers":{},"formCustomers":{},"keyGenerationNumbers":"\#(secret)"}"#,"keyGenerationNumbers"),
            (#"{"namespace":7,"dumpSHA256":"00","customers":{},"formCustomers":{}}"#,"namespace"),
        ]
        for (text,field) in cases {
            XCTAssertThrowsError(try ImportPlan.decode(Data(text.utf8))) { error in
                XCTAssertEqual(String(describing:error),"Plan nicht lesbar: \(field)")
                XCTAssertFalse(String(describing:error).contains(secret)); XCTAssertFalse(String(describing:error).contains("database"))
            }
        }
        XCTAssertThrowsError(try ImportPlan.decode(Data("{not json".utf8))) { error in
            XCTAssertEqual(String(describing:error),"Plan nicht lesbar: kein gültiges JSON")
        }
    }

    func testCommandParametersNameTheCauseNeverTheValue() throws {
        let good = ["FORM_MIGRATION_HMAC_KEY":Data(repeating:1,count:32).base64EncodedString(),"FORM_SERVER_KEY_FILE":"/k","LEGACY_DB_HOST":"h","LEGACY_DB_NAME":"n","LEGACY_DB_USER":"u","LEGACY_DB_PASSWORD":"p-secret"]
        XCTAssertNoThrow(try MigrateLegacyCommand.Parameters.read(plan:"/p",batchSize:nil,env:good))
        func message(_ plan: String?, _ batch: Int? = nil, _ env: [String:String]) -> String {
            do { _ = try MigrateLegacyCommand.Parameters.read(plan:plan,batchSize:batch,env:env); return "no error" } catch { return String(describing:error) }
        }
        XCTAssertEqual(message(nil,nil,good),"Parameter fehlt: --plan")
        XCTAssertEqual(message("/p",0,good),"Parameter ungültig: --batch-size (erlaubt 1 bis 10000)")
        for name in good.keys.sorted() {
            var env = good; env[name] = nil
            XCTAssertEqual(message("/p",nil,env),"Parameter fehlt: \(name)")
        }
        var short = good; short["FORM_MIGRATION_HMAC_KEY"] = Data(repeating:1,count:8).base64EncodedString()
        XCTAssertEqual(message("/p",nil,short),"Parameter ungültig: FORM_MIGRATION_HMAC_KEY (erwartet 32 Byte Base64)")
        var tls = good; tls["LEGACY_DB_TLS"] = "disable"
        XCTAssertEqual(message("/p",nil,tls),"Parameter ungültig: LEGACY_DB_TLS (disable nur mit FORM_ALLOW_INSECURE_DEV=1)")
        XCTAssertFalse(message("/p",nil,short).contains("p-secret"))
    }

    func testExitCodesSeparateInputErrorsFromFailuresAndInterruption() {
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:CLIInputError.missing("--plan")),2)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:CLIInputError.planUnreadable(field:"namespace")),2)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:ImportFailure.invalidPlan),2)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:ImportFailure.invalidPlanField("namespace")),2)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:ImportFailure.conflict),1)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:ImportFailure.database),1)
        XCTAssertEqual(MigrateLegacyCommand.exitCode(for:ImportFailure.interrupted),130)
        XCTAssertEqual(MigrateLegacyCommand.openCasesExitCode,3)
        XCTAssertEqual(String(describing:ImportFailure.invalidPlanField("namespace")),"migration: invalidPlan field=namespace")
    }
}
