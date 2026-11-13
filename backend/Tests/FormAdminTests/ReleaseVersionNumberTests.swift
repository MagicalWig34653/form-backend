// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormPersistence
import Foundation
import SQLKit
import XCTest

/// An imported form already holds form_versions.version_no=1 (contract "migration-review") without a resource_versions row.
/// The first release of its converted draft must take the next free number instead of colliding with it (HTTP 500 before).
final class ReleaseVersionNumberTests: XCTestCase {
    func testFirstReleaseOfAnImportedFormSkipsTheImportedVersionNumber() async throws {
        try await AdminFixture.with { fx in
            let c = try await fx.customer(), f = try await fx.form(customer: c)
            let definition = "{\"legacy\":true}"
            try await fx.sql.raw("""
                INSERT INTO form_versions (customer_id,form_id,version_no,contract_version,definition_json,definition_sha256,encryption_profile,validation_profile,legacy_adapter_ref,special_categories,storage_backend,max_upload_bytes,created_at)
                VALUES (\(bind: DB.bin(c)),\(bind: DB.bin(f)),1,'migration-review',\(bind: definition),UNHEX(SHA2(\(bind: definition),256)),'hpke-v2','legacy-v1','inactive:migration-review',0,'db',10485760,'1970-01-01 00:00:00')
                """).run()
            let v = try await ReleaseRoutes.version(fx.sql, tenant: c, kind: "form", id: f, semver: "1.0.0", hash: Data(repeating: 7, count: 32))
            XCTAssertEqual(v.no, 2, "version 1 belongs to the import")
            XCTAssertTrue(v.isNew)
            // Idempotent for the same semver and content, and other kinds keep their own numbering.
            let again = try await ReleaseRoutes.version(fx.sql, tenant: c, kind: "form", id: f, semver: "1.0.0", hash: Data(repeating: 7, count: 32))
            XCTAssertEqual(again.no, 2); XCTAssertFalse(again.isNew)
            let view = try await ReleaseRoutes.version(fx.sql, tenant: c, kind: "view", id: f, semver: "1.0.0", hash: Data(repeating: 8, count: 32))
            XCTAssertEqual(view.no, 1)
        }
    }
}
