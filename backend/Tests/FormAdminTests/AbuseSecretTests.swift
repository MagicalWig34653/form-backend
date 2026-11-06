// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormAuth
import FormPersistence
import Foundation
import SQLKit
import XCTVapor
import XCTest

/// Compile-only in this package; run with MariaDB during the separate DB acceptance.
final class AbuseSecretTests: XCTestCase {
    func testSecretOwnershipLiveRevocationCSRFAndValueFreeAudit() async throws {
        try await AdminFixture.with { fx in
            let account = try await fx.account(), customer = try await fx.customer()
            let form = try await fx.form(customer: customer)
            let user = try await fx.login(account)
            let path = "tenants/\(customer.uuidString.lowercased())/forms/\(form.uuidString.lowercased())/abuse-secret"
            let body = #"{"secret":"synthetic-turnstile-secret"}"#
            try await user.send(.PUT, path, body: body) { XCTAssertEqual($0.status, .notFound) }
            try await fx.grant(account, "draft.write", customer: customer, by: account)
            try await user.send(.PUT, path, body: body, csrf: false) { XCTAssertEqual($0.status, .forbidden) }
            try await user.send(.PUT, path, body: body) { res in
                XCTAssertEqual(res.status, .ok)
                XCTAssertFalse(res.body.string.contains("synthetic-turnstile-secret"))
                XCTAssertFalse(res.body.string.contains("s1:"))
            }
            struct Secret: Decodable { let secret_ref: String }
            let reference = try await fx.sql.raw("SELECT secret_ref FROM form_abuse_secrets WHERE form_id=\(bind: DB.bin(form))").first(decoding: Secret.self)!
            let store = SecretStore(db: fx.app.db(.mysql), keys: try StaticServerKey(Data(repeating: 7, count: 32)))
            let plain = try await store.get(reference.secret_ref)
            XCTAssertEqual(plain, Data("synthetic-turnstile-secret".utf8))
            struct Audit: Decodable { let safe_details_json: String? }
            let audit = try await fx.sql.raw("SELECT safe_details_json FROM audit_events WHERE action_code='form.abuse.secret.update'").first(decoding: Audit.self)!
            XCTAssertFalse((audit.safe_details_json ?? "").contains("synthetic-turnstile-secret"))
            try await fx.sql.raw("DELETE FROM permission_assignments WHERE account_id=\(bind: DB.bin(account))").run()
            try await user.send(.PUT, path, body: body) { XCTAssertEqual($0.status, .notFound) }
        }
    }
}
