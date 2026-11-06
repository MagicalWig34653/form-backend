// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor

final class AdsStatisticsUnitTests: XCTestCase {
    func testOnlyPresenceBooleanAccepted() throws {
        XCTAssertNil(try AdsIndicator.parse(nil))
        for value in [true, false] { XCTAssertEqual(try AdsIndicator.parse(["gclidPresent": value]), value) }
        for json in ["{\"gclidPresent\":1}", "{\"gclidPresent\":\"true\"}", "{\"gclid\":\"synthetic\"}", "{\"gclidPresent\":true,\"utm_campaign\":\"x\"}", "null"] {
            XCTAssertThrowsError(try AdsIndicator.parse(JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])))
        }
    }
    func testSmallCellsAreSuppressedWithoutTotalsOrIdentifiers() throws {
        let body = AdsStatistics.project([
            .init(segment: "ads", visits: 10, submits: 4),
            .init(segment: "nonAds", visits: 5, submits: 5),
            .init(segment: "unknown", visits: 0, submits: 5)
        ], from: "2026-11-01", to: "2026-11-03")
        XCTAssertTrue(body.suppressed)
        XCTAssertEqual(body.groups.map(\.segment), ["nonAds", "unknown"])
        XCTAssertEqual(body.groups.first?.conversion, 1)
        XCTAssertNil(body.groups.last?.conversion)
        let json = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        for forbidden in ["gclid", "pseudonym", "total", "campaignId"] { XCTAssertFalse(json.contains(forbidden)) }
        XCTAssertFalse(body.campaignsAvailable)
        XCTAssertTrue(AdsStatistics.project([.init(segment: "ads", visits: 4, submits: 0)], from: "", to: "").groups.isEmpty)
    }
}

/// MariaDB integration: write/compile only in this package, never run without Docker fixture.
final class AdsStatisticsDBTests: XCTestCase {
    func testRESTBoundsRightsAndUnknownHistory() async throws {
        try await AdminFixture.with { f in
            let account = try await f.account(), tenant = try await f.customer()
            let form = try await f.form(customer: tenant)
            let client = try await f.login(account)
            let path = "tenants/\(tenant)/forms/\(form)/statistics/ads"
            try await client.get(path) { XCTAssertEqual($0.status, .notFound) }
            try await f.grant(account, "statistics.read", customer: tenant, form: form, by: account)
            for days in ["0", "367", "x"] {
                try await client.get(path + "?days=" + days) { XCTAssertEqual($0.status, .badRequest) }
            }
            try await client.get(path + "?days=366") {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(jsonObject($0)["campaignsAvailable"] as? Bool, false)
                XCTAssertEqual((jsonObject($0)["groups"] as? [Any])?.count, 0)
                XCTAssertEqual($0.headers.first(name: .cacheControl), "no-store")
            }
            let otherTenant = try await f.customer(), otherForm = try await f.form(customer: otherTenant)
            try await client.get("tenants/\(otherTenant)/forms/\(otherForm)/statistics/ads") { XCTAssertNotEqual($0.status, .ok) }
            try await f.sql.raw("UPDATE permission_assignments SET revoked_at=NOW() WHERE account_id=\(bind: DB.bin(account))").run()
            try await client.get(path) { XCTAssertEqual($0.status, .notFound) }
        }
    }
}
