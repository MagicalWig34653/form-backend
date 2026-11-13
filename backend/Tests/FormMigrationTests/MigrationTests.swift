// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Crypto
import Foundation
import Vapor
import SQLKit
import FluentMySQLDriver
import FormCore
import FormAuth
import FormCrypto
import FormPersistence
@testable import FormMigration
@testable import FormAdmin

final class MigrationTests: XCTestCase {
    let form = "11111111-1111-4111-8111-111111111111"
    let customer = "33333333-3333-4333-8333-333333333333"
    func withDatabases(_ body: (SQLDatabase,SQLDatabase,SecretStore) async throws -> Void) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["P4A_DB_PORT"], let password = env["P4A_DB_PASSWORD"] else { throw XCTSkip("Integration benötigt backend/integration-test.sh") }
        let app = try await Application.make(.testing)
        let suffix = UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let sourceName = "migration_old_" + suffix, targetName = "migration_new_" + suffix
        var logger = app.logger; logger.logLevel = .critical
        func register(_ name: String, _ id: DatabaseID) {
            let cfg = MySQLConfiguration(hostname:env["P4A_DB_HOST"] ?? "127.0.0.1",port:Int(port)!,username:"root",password:password,database:name,tlsConfiguration:nil)
            app.databases.use(.mysql(configuration:cfg,maxConnectionsPerEventLoop:2),as:id)
        }
        register("p4atest",.mysql)
        let admin = app.db(.mysql,logger:logger) as! SQLDatabase
        do {
            try await admin.raw("CREATE DATABASE \(ident:sourceName)").run()
            try await admin.raw("CREATE DATABASE \(ident:targetName)").run()
            let sourceID = DatabaseID(string:"migration-source"), targetID = DatabaseID(string:"migration-target")
            register(sourceName,sourceID); register(targetName,targetID)
            let src = app.db(sourceID,logger:logger) as! SQLDatabase
            let database = app.db(targetID,logger:logger), dst = database as! SQLDatabase
            let fixture = try String(contentsOf:Bundle.module.url(forResource:"legacy",withExtension:"sql",subdirectory:"Fixtures")!,encoding:.utf8)
            for statement in try SQLStatementSplitter.split(fixture) { try await src.raw(query(statement)).run() }
            let schema = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("db/schema-p3.sql").path
            _ = try await MigrationRunner(db:dst).run(schemaFile:schema)
            try await body(src,dst,SecretStore(db:database,keys:StaticServerKey(Data(repeating:7,count:32))))
        } catch {
            try? await admin.raw("DROP DATABASE IF EXISTS \(ident:sourceName)").run(); try? await admin.raw("DROP DATABASE IF EXISTS \(ident:targetName)").run()
            try? await app.asyncShutdown(); throw error
        }
        try await admin.raw("DROP DATABASE \(ident:sourceName)").run(); try await admin.raw("DROP DATABASE \(ident:targetName)").run()
        try await app.asyncShutdown()
    }
    func fingerprint(_ importer: LegacyImporter, _ db: SQLDatabase, ignoring: Set<String> = []) async throws -> String {
        let tables = try await db.raw("SELECT table_name AS v FROM information_schema.tables WHERE table_schema=DATABASE() ORDER BY table_name").all(decoding:TextRow.self)
        var combined = ""
        for table in tables where !ignoring.contains(table.v) {
            let columns = try await importer.columns(db,table.v)
            let projection = try await importer.projection(db,table.v,columns)
            let rows = try await db.raw(query("SELECT \(projection) AS v FROM \(try ident(table.v))")).all(decoding:TextRow.self)
            combined += table.v + rows.map(\.v).sorted().joined()
        }
        return importer.mac(combined)
    }
    func testMigrationProjectionHandlesNumericUUIDAndBinaryColumns() async throws {
        try await withDatabases { src,dst,secrets in
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            // Isolate SQL conversion from the import stages: HEX(INT) previously yielded "1", not "31".
            let oldHex = try await importer.scalar(src,"SELECT HEX(1) AS v")
            XCTAssertEqual(oldHex,"1")
            try await src.raw("""
                CREATE TABLE migration_projection (
                    ID BIGINT NOT NULL, epoch INT NOT NULL, amount DECIMAL(12,2) NOT NULL,
                    flag BOOLEAN NOT NULL, nativeUUID UUID NOT NULL, textUUID CHAR(36) NOT NULL,
                    binaryUUID BINARY(16) NOT NULL, payload LONGBLOB NOT NULL, optional TEXT NULL, label TEXT NOT NULL)
                """).run()
            let uuid = "aabbccdd-1111-4111-8111-aabbccddeeff"
            let binaryID = DB.bin(try XCTUnwrap(UUID(uuidString:uuid)))
            let payload = Data([0,255,128,65])
            try await src.raw("""
                INSERT INTO migration_projection (ID,epoch,amount,flag,nativeUUID,textUUID,binaryUUID,payload,label)
                VALUES (1,1700000000,123.45,0,\(bind:uuid),\(bind:uuid.uppercased()),\(bind:binaryID),\(bind:Blob(payload)),\(bind:"Grüße"))
                """).run()
            let cols = try await importer.columns(src,"migration_projection")
            let projection = try await importer.projection(src,"migration_projection",cols)
            let wire = try await importer.scalar(src,"SELECT \(projection) AS v FROM migration_projection")
            let row = try LegacyRow.decode(XCTUnwrap(wire),table:"migration_projection")
            XCTAssertEqual(try row.required("ID"),"1")
            XCTAssertEqual(try row.required("epoch"),"1700000000")
            XCTAssertEqual(try row.required("amount"),"123.45")
            XCTAssertEqual(try row.required("flag"),"0")
            XCTAssertEqual(try row.required("nativeUUID"),uuid)
            XCTAssertEqual(try row.required("textUUID"),uuid.uppercased())
            XCTAssertEqual(try row.uuid("nativeUUID"),try row.uuid("textUUID"))
            XCTAssertEqual(try row.bytes("binaryUUID"),binaryID.data)
            XCTAssertEqual(try row.bytes("payload"),payload)
            XCTAssertEqual(try row.required("label"),"Grüße")
            XCTAssertNil(try row.text("optional"))
        }
    }
    func testMigrationDryRunResumeIdempotencyAndParity() async throws {
        try await withDatabases { src,dst,secrets in
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"synthetic",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            let dry = try await importer.run(plan:plan,dryRun:true,batchSize:1)
            XCTAssertTrue(dry.dryRun)
            let empty = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM customers")
            XCTAssertEqual(empty,"0")
            let runs = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_runs")
            XCTAssertEqual(runs,"0")
            let dryPeriods = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM settings")
            XCTAssertEqual(dryPeriods,"0","the dry run leaves no retention period behind")
            do { _ = try await importer.run(plan:plan,batchSize:1,stopAfter:1); XCTFail("Expected interruption") } catch ImportFailure.interrupted {}
            let first = try await importer.run(plan:plan,batchSize:1)
            let objects = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_objects")
            let beforeFingerprint = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            let second = try await importer.run(plan:plan,batchSize:2)
            let afterFingerprint = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            XCTAssertEqual(beforeFingerprint,afterFingerprint)
            let after = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_objects")
            XCTAssertEqual(objects,after)
            XCTAssertEqual(try json(first),try json(second))
            XCTAssertEqual(second.tables["formulare"]?.sourceCount,1)
            XCTAssertEqual(second.tables["anfragen"]?.importedCount,1)
            XCTAssertFalse(second.cutoverReady)
            let state = try await importer.scalar(dst,"SELECT state AS v FROM submissions")
            XCTAssertEqual(state,"migration-review")
            let hold = try await importer.scalar(dst,"SELECT CAST(removable AS CHAR) AS v FROM submissions")
            XCTAssertEqual(hold,"0")
            // ADR 0012 no. 2: the imported form gets the default period (3 days), the imported submission its due date from it
            let period = try await importer.scalar(dst,"SELECT CAST(safe_value_json AS CHAR) AS v FROM settings WHERE scope_key='form:\(self.form)' AND setting_key='retention.days'")
            XCTAssertEqual(period,"3")
            let dueDays = try await importer.scalar(dst,"SELECT CAST(DATEDIFF(retention_due_at,received_at) AS CHAR) AS v FROM submissions")
            XCTAssertEqual(dueDays,"3")
            let evidence = try await importer.scalar(dst,"SELECT digest_evidence AS v FROM ingest_idempotency")
            XCTAssertEqual(evidence,"legacy-missing")
            try await dst.raw("UPDATE forms SET name='tampered'").run()
            do { _ = try await importer.run(plan:plan); XCTFail("Expected target conflict") } catch ImportFailure.conflict {}
        }
    }
    /// Operator path (finding A, 13.11.2026): a customer created by the import is ACTIVE (visible under Kunden, its forms, drafts and entries are
    /// reachable); forms, connections and releases stay inactive, so nothing is received or sent before the cutover. A repeated run and a second
    /// importer instance on the same plan pass without conflict; an existing target customer keeps its state.
    func testImportedCustomerIsActiveWhileFormsAndConnectionsStayInactive() async throws {
        try await withDatabases { src,dst,secrets in
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"synthetic",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            _ = try await importer.run(plan:plan,batchSize:1)
            let state = try await importer.scalar(dst,"SELECT state AS v FROM customers")
            XCTAssertEqual(state,"active","an imported customer must be usable after the import")
            let live = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM forms WHERE active=1 OR current_release_id IS NOT NULL")
            XCTAssertEqual(live,"0","imported forms stay inactive and unreleased")
            let sending = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM connections WHERE enabled=1")
            XCTAssertEqual(sending,"0","imported connections stay disabled")
            let grants = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM permission_assignments")
            XCTAssertEqual(grants,"0","no account gets access to the imported customer by the import")
            let before = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            _ = try await importer.run(plan:plan,batchSize:2)
            let again = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            _ = try await again.run(plan:plan,batchSize:3)
            let after = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            XCTAssertEqual(before,after,"repetition changes nothing and raises no conflict")
        }
        try await withDatabases { src,dst,secrets in
            // An existing (here deliberately disabled) target customer of the same name is taken over as it is.
            try await dst.raw("INSERT INTO customers (id,name,state,created_at) VALUES (UNHEX(REPLACE('\(unsafeRaw: self.customer)','-','')),'Testkunde','disabled',UTC_TIMESTAMP(6))").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"synthetic",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            _ = try await importer.run(plan:plan,batchSize:1)
            let state = try await importer.scalar(dst,"SELECT state AS v FROM customers")
            XCTAssertEqual(state,"disabled","an existing target customer keeps its state")
        }
    }
    /// A period that already exists for the target form is kept; the imported submissions get exactly that one.
    func testMigrationKeepsAnExistingRetentionPeriodForTheImportedSubmissions() async throws {
        try await withDatabases { src,dst,secrets in
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"synthetic",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            try await dst.raw("INSERT INTO settings (scope_key,setting_key,safe_value_json,manageable,modified_at) VALUES (\(bind:"form:"+self.form),'retention.days','5',1,NOW(6))").run()
            _ = try await importer.run(plan:plan,batchSize:1)
            let period = try await importer.scalar(dst,"SELECT CAST(safe_value_json AS CHAR) AS v FROM settings WHERE scope_key='form:\(self.form)'")
            XCTAssertEqual(period,"5")
            let dueDays = try await importer.scalar(dst,"SELECT CAST(DATEDIFF(retention_due_at,received_at) AS CHAR) AS v FROM submissions")
            XCTAssertEqual(dueDays,"5")
            // resuming compares the snapshots (incl. the due date) and stays green
            _ = try await importer.run(plan:plan,batchSize:2)
        }
    }
    func testMigrationIncludesNegativeIDsAcrossBatches() async throws {
        try await withDatabases { src,dst,secrets in
            let other = "66666666-6666-4666-8666-666666666666"
            try await src.raw("INSERT INTO formulare (ID,UUID,name) VALUES (-2,\(bind:other),'Negative ID')").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"negative",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer,other:self.customer])
            let report = try await importer.run(plan:plan,batchSize:1)
            XCTAssertEqual(report.inventory["formulare"],2)
            XCTAssertEqual(report.tables["formulare"]?.sourceCount,2)
            XCTAssertEqual(report.tables["formulare"]?.importedCount,2)
            let count = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM forms")
            XCTAssertEqual(count,"2")
        }
    }

    func testMigrationRefusesVerificationWhenCursorMissesInventoryRows() async throws {
        try await withDatabases { src,dst,secrets in
            // A malformed source with duplicate cursor keys would otherwise silently skip a row.
            let other = "66666666-6666-4666-8666-666666666666"
            try await src.raw("INSERT INTO formulare (ID,UUID,name) VALUES (1,\(bind:other),'Duplicate cursor')").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"missing",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer,other:self.customer])
            do {
                _ = try await importer.run(plan:plan,batchSize:1)
                XCTFail("Expected inventory mismatch")
            } catch ImportFailure.invalidSourceAt(let table,let column,let reason) {
                XCTAssertEqual(table,"formulare"); XCTAssertEqual(column,"ID"); XCTAssertEqual(reason,.countMismatch)
            }
            let state = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertEqual(state,"failed")
        }
    }

    func testMigrationPopulatedUnknownConfigurationColumnRequiresReviewOnResume() async throws {
        try await withDatabases { src,dst,secrets in
            try await src.raw("ALTER TABLE formulare ADD unknownConfig TEXT NULL, ADD emptyConfig TEXT NULL").run()
            try await src.raw("UPDATE formulare SET unknownConfig='synthetic-config',emptyConfig=''").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"columns",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            for _ in 0..<2 {
                let report = try await importer.run(plan:plan,batchSize:1)
                XCTAssertEqual(report.tables["formulare"]?.importedCount,1)
                XCTAssertEqual(report.tables["formulare"]?.reviewCount,1)
                let issues = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_issues WHERE source_table='formulare' AND issue_code='unmapped-column' AND state='open'")
                XCTAssertEqual(issues,"1")
                let state = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
                XCTAssertEqual(state,"failed")
                // Force the next ledger-only pass to discover the mapping issue again.
                try await dst.raw("DELETE FROM migration_issues WHERE issue_code='unmapped-column'").run()
            }
        }
    }

    func testMigrationRetryUpdatesStateAndCompletionWithUnchangedReport() async throws {
        try await withDatabases { src,dst,secrets in
            try await src.raw("UPDATE anfragen SET data=NULL").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"retry",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            let first = try await importer.run(plan:plan)
            // The fixture mixes ID and lower-case field keys and includes a NULL rule.
            // A serialization-order mismatch must not create a persistent review issue.
            XCTAssertEqual(first.tables["formularFelder"]?.importedCount,1)
            let initialState = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertEqual(initialState,"verified")
            let openIssues = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_issues WHERE state='open'")
            XCTAssertEqual(openIssues,"0")
            let originalReport = try await importer.scalar(dst,"SELECT report_json AS v FROM migration_runs")
            do { _ = try await importer.run(plan:plan,stopAfter:1); XCTFail("Expected interruption") } catch ImportFailure.interrupted {}
            let failed = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertEqual(failed,"failed")
            try await dst.raw("UPDATE migration_runs SET completed_at='2000-01-01 00:00:00'").run()
            let second = try await importer.run(plan:plan)
            XCTAssertEqual(try json(first),try json(second))
            let savedReport = try await importer.scalar(dst,"SELECT report_json AS v FROM migration_runs")
            XCTAssertEqual(originalReport,savedReport)
            let state = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertEqual(state,"verified")
            let completed = try await importer.scalar(dst,"SELECT IF(completed_at > '2000-01-01 00:00:00','updated','stale') AS v FROM migration_runs")
            XCTAssertEqual(completed,"updated")
        }
    }

    func testMigrationV2PackagesSecretsAndStatistics() async throws {
        try await withDatabases { src,dst,secrets in
            let key = Curve25519.KeyAgreement.PrivateKey()
            let pub = key.publicKey.rawRepresentation, kid = try FormCrypto.keyID(pub)
            let wire = try PackageV2.seal(Data("synthetic-only".utf8),recipient:pub).wire
            try await src.raw("UPDATE anfragen SET data=\(bind:wire),sentServer=NULL").run()
            try await src.raw("INSERT INTO outgoingMailServer (ID,UUID,name,SMTPPassword,fromMail) VALUES (1,'44444444-4444-4444-8444-444444444444','synthetic','synthetic-password','test@example.invalid')").run()
            try await src.raw("INSERT INTO statistics (ID,UUID,formularUUID,status,gclid,userAgent,domain) VALUES (1,'55555555-5555-4555-8555-555555555555',\(bind:self.form),'SUCCESS','synthetic-ad','synthetic-UA','192.0.2.1')").run()
            try await src.raw(query("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(val(kid)),\(bin(pub)),'aktiv',1700000000,\(val(self.customer)))")).run()
            try await src.raw("INSERT INTO statistics (ID,UUID,formularUUID,status) VALUES (2,'55555555-5555-4555-8555-555555555555',\(bind:self.form),'SUCCESS')").run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"synthetic",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer],connectionCustomers:["44444444-4444-4444-8444-444444444444":[self.customer]],keyCustomers:[kid:self.customer],keyGenerationNumbers:[kid:1],statisticsReview:"fixture-approved",statisticsPublicKeys:[self.customer:pub.base64EncodedString()])
            let report = try await importer.run(plan:plan)
            XCTAssertEqual(report.tables["statistics"]?.importedCount,2)
            let ref = try await importer.scalar(dst,"SELECT credential_ref AS v FROM connections")
            let credential = try await secrets.get(XCTUnwrap(ref))
            XCTAssertTrue(String(decoding:try XCTUnwrap(credential),as:UTF8.self).contains("synthetic-password"))
            let savedWire = try await importer.scalar(dst,"SELECT CONVERT(ciphertext USING utf8mb4) AS v FROM stored_objects WHERE object_role='data'")
            XCTAssertEqual(savedWire,wire)
            let jobID = DB.bin(UUID())
            try await dst.raw("INSERT INTO migration_jobs(id,actor_id,source_json,plan_json,expected_schema,state,phase,dry_run,report_json,created_at,updated_at) VALUES(\(bind: jobID),\(bind: DB.bin(UUID())),'{}',\(bind: MigrationService.encode(plan)),\(bind: String(repeating: "0", count: 64)),'review','verification',0,'{}',UTC_TIMESTAMP(6),UTC_TIMESTAMP(6))").run()
            let storedJob = try await dst.raw("SELECT * FROM migration_jobs WHERE id=\(bind: jobID)").first(decoding: MigrationJob.self)
            let job = try XCTUnwrap(storedJob)
            let probe = try await MigrationVerificationRoutes.sample(dst, job: job)
            XCTAssertEqual(probe, wire)
            XCTAssertEqual(MigrationVerificationRoutes.hash(probe), SHA256.hash(data: Data(wire.utf8)).map { String(format: "%02x", $0) }.joined())

            let metadataWire = try await importer.scalar(dst,"SELECT CONVERT(ciphertext USING utf8mb4) AS v FROM stored_objects WHERE object_role='statistics-metadata' ORDER BY id LIMIT 1")
            let metadata = try PackageV2(XCTUnwrap(metadataWire)).open(recipient:key)
            XCTAssertNotNil(try JSONSerialization.jsonObject(with:metadata) as? [String:Any])
            let flags = try await importer.scalar(dst,"SELECT CAST(has_ip_reference AS CHAR) AS v FROM legacy_statistics WHERE source_id=1")
            XCTAssertEqual(flags,"1")
            let first = try json(report), second = try json(await importer.run(plan:plan))
            XCTAssertEqual(first,second)
        }
    }
}

extension MigrationTests {
    /// Legacy recovery envelopes (bvk migration 034, `datenschluesselRecovery`) are copied byte for byte into data_key_recovery,
    /// only for a generation mapped to and imported for the plan customer; anything else becomes a review case (ADR 0037).
    func testMigrationCopiesLegacyRecoveryEnvelopeExactly() async throws {
        try await withDatabases { src,dst,secrets in
            try await src.raw("""
                CREATE TABLE `datenschluesselRecovery` (
                    `kid` char(16) NOT NULL, `salt` varbinary(32) NOT NULL, `iterationen` int(11) NOT NULL,
                    `iv` varbinary(12) NOT NULL, `wrap` varbinary(48) NOT NULL, `erstelltAm` int(11) NOT NULL,
                    PRIMARY KEY (`kid`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
                """).run()
            let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, kid = try FormCrypto.keyID(pub)
            // a second legacy generation that the plan does not assign to any customer
            let foreignPub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, foreignKid = try FormCrypto.keyID(foreignPub)
            try await src.raw(query("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(val(kid)),\(bin(pub)),'aktiv',1700000000,\(val(self.customer)))")).run()
            // synthetic bytes, including 0x00 and 0xff, so that any text or charset conversion would show
            let salt = Data((0..<32).map { UInt8(($0 * 37 + 255) % 256) }), iv = Data((0..<12).map { UInt8(255 - $0) }), wrap = Data((0..<48).map { UInt8(($0 * 91) % 256) })
            try await src.raw(query("INSERT INTO datenschluesselRecovery (kid,salt,iterationen,iv,wrap,erstelltAm) VALUES (\(val(kid)),\(bin(salt)),600000,\(bin(iv)),\(bin(wrap)),1700000001)")).run()
            try await src.raw(query("INSERT INTO datenschluesselRecovery (kid,salt,iterationen,iv,wrap,erstelltAm) VALUES (\(val(foreignKid)),\(bin(salt)),600000,\(bin(iv)),\(bin(wrap)),1700000001)")).run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"recovery",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer],keyCustomers:[kid:self.customer],keyGenerationNumbers:[kid:1])
            let report = try await importer.run(plan:plan,batchSize:1)
            XCTAssertEqual(report.inventory["datenschluesselRecovery"],2)
            XCTAssertEqual(report.tables["datenschluesselRecovery"]?.sourceCount,2)
            XCTAssertEqual(report.tables["datenschluesselRecovery"]?.importedCount,1)
            XCTAssertEqual(report.tables["datenschluesselRecovery"]?.reviewCount,1)
            struct R: Decodable { let kid: String; let kdf_name: String; let salt: Blob; let iterations: Int; let iv: Blob; let wrapped_key: Blob; let customer_id: Blob }
            let rows = try await dst.raw("SELECT kid,kdf_name,salt,iterations,iv,wrapped_key,customer_id FROM data_key_recovery").all(decoding:R.self)
            XCTAssertEqual(rows.count,1)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.kid,kid); XCTAssertEqual(row.kdf_name,"pbkdf2-hmac-sha256"); XCTAssertEqual(row.iterations,600000)
            XCTAssertEqual(row.salt.data,salt); XCTAssertEqual(row.iv.data,iv); XCTAssertEqual(row.wrapped_key.data,wrap)
            XCTAssertEqual(row.customer_id.data,DB.bin(try XCTUnwrap(UUID(uuidString:self.customer))).data)
            // the unassigned generation is a review case, not an import (no guessing of a customer)
            let issue = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_issues WHERE source_table='datenschluesselRecovery' AND source_key=\(bin(Data(foreignKid.utf8))) AND state='open'")
            XCTAssertEqual(issue,"1")
            // no access envelope is created by the importer: adoption happens in the browser
            let access = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM data_key_access")
            XCTAssertEqual(access,"0")
            // idempotent rerun; tampering with the copied envelope is detected
            let before = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            let again = try await importer.run(plan:plan,batchSize:2)
            XCTAssertEqual(try json(report),try json(again))
            let afterRun = try await self.fingerprint(importer,dst,ignoring:["migration_runs"])
            XCTAssertEqual(before,afterRun)
            try await dst.raw("UPDATE data_key_recovery SET wrapped_key=\(bind:Blob(Data(repeating:1,count:48)))").run()
            do { _ = try await importer.run(plan:plan); XCTFail("Expected target conflict") } catch ImportFailure.conflict {}
        }
    }

    func testMigrationRecoveryEnvelopeWithForeignShapeIsReviewed() async throws {
        try await withDatabases { src,dst,secrets in
            try await src.raw("""
                CREATE TABLE `datenschluesselRecovery` (
                    `kid` char(16) NOT NULL, `salt` varbinary(32) NOT NULL, `iterationen` int(11) NOT NULL,
                    `iv` varbinary(12) NOT NULL, `wrap` varbinary(48) NOT NULL, `erstelltAm` int(11) NOT NULL,
                    PRIMARY KEY (`kid`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci
                """).run()
            let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, kid = try FormCrypto.keyID(pub)
            try await src.raw(query("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(val(kid)),\(bin(pub)),'auslaufend',1700000000,\(val(self.customer)))")).run()
            // iteration count differs from the contract (600000): never imported, the browser would refuse it anyway
            try await src.raw(query("INSERT INTO datenschluesselRecovery (kid,salt,iterationen,iv,wrap,erstelltAm) VALUES (\(val(kid)),\(bin(Data(repeating:1,count:32))),100000,\(bin(Data(repeating:2,count:12))),\(bin(Data(repeating:3,count:48))),1700000001)")).run()
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"recovery-shape",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer],keyCustomers:[kid:self.customer],keyGenerationNumbers:[kid:1])
            let report = try await importer.run(plan:plan)
            XCTAssertEqual(report.tables["datenschluesselRecovery"]?.importedCount,0)
            XCTAssertEqual(report.tables["datenschluesselRecovery"]?.reviewCount,1)
            let rows = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM data_key_recovery")
            XCTAssertEqual(rows,"0")
            let state = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertEqual(state,"failed")
        }
    }

    /// Uses only legacy.sql's schema and synthetic rows: 3 forms / 28 fields, never the real dump.
    func testConversionOfImportedSyntheticThreeFormsAnd28Fields() async throws {
        try await withDatabases { src, dst, secrets in
            let ids = [self.form, "44444444-4444-4444-8444-444444444444", "55555555-5555-4555-8555-555555555555"]
            for (index, id) in ids.enumerated() {
                if index > 0 { try await src.raw("INSERT INTO formulare (ID,UUID,name,active) VALUES (\(bind:index+1),\(bind:id),'Synthetisch',1)").run() }
                for field in 0..<9 {
                    try await src.raw("INSERT INTO formularFelder (formularUUID,feldName,typ,pflicht,reihenfolge) VALUES (\(bind:id),\(bind:"field_\(field)"),'text',1,\(bind:field+1))").run()
                }
            }
            let importer = try LegacyImporter(source: src, target: dst, secrets: secrets, hmacKey: Data(repeating: 8,count: 32))
            let plan = ImportPlan(namespace:"synthetic-converter",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:Dictionary(uniqueKeysWithValues:ids.map { ($0,self.customer) }))
            _ = try await importer.run(plan: plan)
            struct Definition: Decodable { let definition_json: String; let form_id: Blob }
            let rows = try await dst.raw("SELECT definition_json, form_id FROM form_versions ORDER BY form_id").all(decoding:Definition.self)
            XCTAssertEqual(rows.count, 3)
            var count = 0
            for row in rows {
                let p = try JSONDecoder().decode(LegacyFormConverter.Projection.self, from:Data(row.definition_json.utf8))
                count += p.legacyFields.count
                let formID = try XCTUnwrap(DB.uuid(row.form_id.data)), tenantID = try XCTUnwrap(UUID(uuidString:self.customer))
                let result = try LegacyFormConverter.convert(Data(row.definition_json.utf8), standardDocument: DraftStore.standardDocument(tenant:tenantID, form:formID, name:"Formular"))
                _ = try DocumentValidator.validate(result.document, tenant:tenantID, form:formID)
                XCTAssertTrue(p.legacyFields.allSatisfy { ($0["typ"] ?? nil) != nil })
            }
            XCTAssertEqual(count,28)
            let active = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM forms WHERE active=1")
            XCTAssertEqual(active,"0")
            let releases = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM releases")
            XCTAssertEqual(releases,"0")
        }
    }
}

extension MigrationTests {
    /// Card A5F93B32 (7 CLI findings), findings 5 and 7: a statistics row without approval or without a key generation of the customer
    /// is a NAMED review case; the rest of the import runs and nothing statistical is written (before: unknownKeyGeneration aborted the run).
    func testStatisticsWithoutApprovalOrKnownKeyBecomeNamedReviewCasesAndRunContinues() async throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), foreign = Curve25519.KeyAgreement.PrivateKey()
        let kid = try FormCrypto.keyID(key.publicKey.rawRepresentation)
        // One fresh source/target pair per scenario (a form can be in the ledger of one namespace only).
        func scenario(review: String?, publicKey: Curve25519.KeyAgreement.PrivateKey?) async throws -> (codes: String, report: ImportReport, written: String, open: Int) {
            var result: (String, ImportReport, String, Int)?
            try await withDatabases { src,dst,secrets in
                try await src.raw(query("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(val(kid)),\(bin(key.publicKey.rawRepresentation)),'aktiv',1700000000,\(val(self.customer)))")).run()
                try await src.raw("INSERT INTO statistics (ID,UUID,formularUUID,status,gclid) VALUES (1,'55555555-5555-4555-8555-555555555551',\(bind:self.form),'SUCCESS','synthetic-ad')").run()
                try await src.raw("INSERT INTO statistics (ID,UUID,formularUUID,status) VALUES (2,'55555555-5555-4555-8555-555555555552',\(bind:self.form),'SUCCESS')").run()
                let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
                let keys = publicKey.map { [self.customer:$0.publicKey.rawRepresentation.base64EncodedString()] } ?? [:]
                let plan = ImportPlan(namespace:"stat",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer],keyCustomers:[kid:self.customer],keyGenerationNumbers:[kid:1],statisticsReview:review,statisticsPublicKeys:keys)
                let report = try await importer.run(plan:plan)
                let codes = try await importer.scalar(dst,"SELECT COALESCE(GROUP_CONCAT(DISTINCT CONCAT(source_table,':',issue_code) ORDER BY issue_code),'') AS v FROM migration_issues WHERE source_table='statistics'") ?? ""
                let written = try await importer.scalar(dst,"SELECT CONCAT((SELECT COUNT(*) FROM legacy_statistics),'/',(SELECT COUNT(*) FROM stored_objects WHERE object_role='statistics-metadata')) AS v") ?? ""
                result = (codes,report,written,try await importer.openCases(namespace:"stat"))
            }
            return try XCTUnwrap(result)
        }
        // 7: no approval -> own code
        let noReview = try await scenario(review:nil,publicKey:key)
        XCTAssertEqual(noReview.codes,"statistics:statistics-review-missing"); XCTAssertEqual(noReview.written,"0/0")
        // 5: approved, but the key is no generation of the customer -> own code, the run does not abort, the forms are imported
        let unknown = try await scenario(review:"approved",publicKey:foreign)
        XCTAssertEqual(unknown.codes,"statistics:statistics-key-unknown")
        XCTAssertEqual(unknown.report.tables["statistics"]?.reviewCount,2)
        XCTAssertEqual(unknown.report.tables["formulare"]?.importedCount,1)
        XCTAssertEqual(unknown.written,"0/0")
        XCTAssertGreaterThanOrEqual(unknown.open,2)
        // approved, no key at all in the plan -> the same named case
        let none = try await scenario(review:"approved",publicKey:nil)
        XCTAssertEqual(none.codes,"statistics:statistics-key-unknown")
        // control: approved with the customer's key -> imported, no case
        let good = try await scenario(review:"approved",publicKey:key)
        XCTAssertEqual(good.codes,""); XCTAssertEqual(good.written,"2/2")
    }

    /// Finding 4: a stop request (signal in the CLI) is honoured at an object boundary by the importer's checkpoint; the run ends
    /// as `failed` (the schema has no paused state, same as the web pause), the lock is free and a repetition resumes to the same end state.
    func testStopRequestAtObjectBoundaryReleasesLockAndResumes() async throws {
        try await withDatabases { src,dst,secrets in
            let importer = try LegacyImporter(source:src,target:dst,secrets:secrets,hmacKey:Data(repeating:8,count:32))
            let plan = ImportPlan(namespace:"stop",dumpSHA256:String(repeating:"0",count:64),customers:[self.customer:"Testkunde"],formCustomers:[self.form:self.customer])
            let stop = StopRequest()
            let seen = Counter()
            do { _ = try await importer.run(plan:plan,checkpoint:{ _,_ in if seen.next() == 3 { stop.request(SIGTERM) }; try stop.check() }); XCTFail("Expected interruption") } catch ImportFailure.interrupted {}
            XCTAssertEqual(stop.signal,SIGTERM)
            let free = try await importer.scalar(dst,"SELECT CAST(IS_FREE_LOCK('form_legacy_import') AS CHAR) AS v")
            XCTAssertEqual(free,"1")
            let state = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertNotEqual(state,"running")
            let partial = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_objects")
            let report = try await importer.run(plan:plan)
            XCTAssertFalse(report.dryRun)
            let all = try await importer.scalar(dst,"SELECT CAST(COUNT(*) AS CHAR) AS v FROM migration_objects")
            XCTAssertNotEqual(partial,all)
            let after = try await importer.scalar(dst,"SELECT state AS v FROM migration_runs")
            XCTAssertNotEqual(after,"running")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
