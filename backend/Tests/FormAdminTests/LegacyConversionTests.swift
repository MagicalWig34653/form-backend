// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import XCTVapor
import SQLKit
import FormCore
import FormPersistence
@testable import FormAdmin

/// DB/API regression: written and compiled only; requires Docker at acceptance.
final class LegacyConversionTests: XCTestCase {
    func testRightsFreshnessCSRFIdempotencyAndInactivity() async throws {
        try await AdminFixture.with { fx in
            let account = try await fx.account(), customer = try await fx.customer()
            let form = try await fx.form(customer: customer), user = try await fx.login(account)
            let path = "migration/legacy-forms/\(form.uuidString.lowercased())/draft"
            try await user.send(.POST, path) { XCTAssertEqual($0.status, .notFound) }
            try await fx.grant(account, "system.manage", customer: customer, by: account)
            try await user.send(.POST, path) { XCTAssertEqual($0.status, .notFound) }
            try await fx.grant(account, "system.manage", system: true, by: account)
            try await user.send(.POST, path) { XCTAssertEqual($0.status, .notFound) } // no legacy version
            let projection = "{\"legacyConfiguration\":{\"name\":\"Synthetic\",\"active\":\"1\"},\"legacyFields\":[{\"feldName\":\"email\",\"typ\":\"email\",\"pflicht\":\"1\"}]}"
            try await fx.sql.raw("""
                INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,legacy_adapter_ref,special_categories,storage_backend,max_upload_bytes,created_at)
                VALUES (\(bind: DB.bin(customer)),\(bind: DB.bin(form)),1,'migration-review',\(bind: projection),\(bind: Blob(Data(repeating: 0,count:32))),'hpke-v2','legacy-v1','inactive:migration-review',0,'db',10485760,UTC_TIMESTAMP(6))
                """).run()
            try await user.send(.POST, path, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            var draftID = ""
            for _ in 0..<2 {
                try await user.send(.POST, path) { response in
                    XCTAssertEqual(response.status, .ok)
                    let id = jsonObject(response)["draftId"] as! String
                    if !draftID.isEmpty { XCTAssertEqual(id, draftID) }; draftID = id
                }
            }
            // A retry must preserve edits made through the normal draft editor.
            let draftUUID = try XCTUnwrap(UUID(uuidString: draftID))
            let edited = DraftStore.standardDocument(tenant: customer, form: form, name: "Menschlich bearbeitet")
            try await fx.sql.raw("UPDATE form_drafts SET document_json = \(bind: String(decoding:JCS.canonicalize(edited),as:UTF8.self)), revision=2 WHERE id=\(bind:DB.bin(draftUUID))").run()
            try await user.send(.POST, path) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(String(buffer: response.body).contains("Menschlich bearbeitet"))
            }
            try await user.get(path) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertNil(jsonObject(response)["document"])
                XCTAssertNil(jsonObject(response)["proposals"])
            }
            struct Count: Decodable { let n: Int }
            for query in ["SELECT COUNT(*) AS n FROM releases", "SELECT COUNT(*) AS n FROM forms WHERE active = 1", "SELECT COUNT(*) AS n FROM domain_bindings"] {
                let count = try await fx.sql.raw(SQLQueryString(stringLiteral: query)).first(decoding: Count.self)
                XCTAssertEqual(count?.n, 0)
            }
            let drafts = try await fx.sql.raw("SELECT COUNT(*) AS n FROM form_drafts").first(decoding: Count.self)
            XCTAssertEqual(drafts?.n, 1)
            let audits = try await fx.sql.raw("SELECT COUNT(*) AS n FROM audit_events WHERE action_code LIKE 'migration.draft.%'").first(decoding: Count.self)
            XCTAssertEqual(audits?.n, 4)
            try await fx.sql.raw("UPDATE forms SET active=1 WHERE id=\(bind:DB.bin(form))").run()
            try await user.send(.POST, path) { XCTAssertEqual($0.status, .conflict) }
            try await fx.sql.raw("UPDATE sessions SET authenticated_at = '2000-01-01' WHERE account_id = \(bind: DB.bin(account))").run()
            try await user.get(path) { XCTAssertEqual($0.status, .forbidden) }
            try await user.send(.POST, path) { XCTAssertEqual($0.status, .forbidden) }
        }
    }
}

extension LegacyConversionTests {
    func testAuditFailureRollsBackDraftAndReport() async throws {
        try await AdminFixture.with { fx in
            let account = try await fx.account(), customer = try await fx.customer()
            let form = try await fx.form(customer:customer), user = try await fx.login(account)
            try await fx.grant(account,"system.manage",system:true,by:account)
            let source = "{\"legacyConfiguration\":{},\"legacyFields\":[]}"
            try await fx.sql.raw("""
                INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,legacy_adapter_ref,special_categories,storage_backend,max_upload_bytes,created_at)
                VALUES (\(bind:DB.bin(customer)),\(bind:DB.bin(form)),1,'migration-review',\(bind:source),\(bind:Blob(Data(repeating:0,count:32))),'hpke-v2','legacy-v1','inactive:migration-review',0,'db',10485760,UTC_TIMESTAMP(6))
                """).run()
            try await fx.sql.raw("CREATE TRIGGER reject_conversion_audit BEFORE INSERT ON audit_events FOR EACH ROW BEGIN IF NEW.action_code = 'migration.draft.create' THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'synthetic audit failure'; END IF; END").run()
            try await user.send(.POST,"migration/legacy-forms/\(form.uuidString.lowercased())/draft") { XCTAssertEqual($0.status,.internalServerError) }
            struct Count: Decodable { let n: Int }
            let drafts = try await fx.sql.raw("SELECT COUNT(*) AS n FROM form_drafts").first(decoding:Count.self)
            let reports = try await fx.sql.raw("SELECT COUNT(*) AS n FROM migration_form_drafts").first(decoding:Count.self)
            XCTAssertEqual(drafts?.n,0); XCTAssertEqual(reports?.n,0)
        }
    }
}
