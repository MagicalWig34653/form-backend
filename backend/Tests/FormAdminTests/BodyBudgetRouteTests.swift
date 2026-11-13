// SPDX-License-Identifier: AGPL-3.0-only
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import XCTest
import XCTVapor
@testable import FormAdmin

/// fb-sec findings 1 and 2 (S2-02): large bodies of the ingest and of the admin replacement/hold routes are reserved in a shared byte
/// budget and, for the admin routes, authenticated BEFORE they are collected. Measurement: the budget counters (`granted`, `peak`,
/// `inFlight`) prove that no reservation, hence no buffering, happens for refused requests. Real MariaDB (backend/integration-test.sh).
/// The out-of-memory behaviour of a real container is covered by backend/e2e-body-budget.sh.
final class BodyBudgetRouteTests: XCTestCase {
    private let mib = 1 << 20
    private func problem(_ r: XCTHTTPResponse) -> String { (jsonObject(r)["code"] as? String) ?? "" }
    private func body(_ n: Int) -> ByteBuffer { ByteBuffer(repeating: 0x41, count: n) }

    func testAnonymousAdminBodiesAreRefusedWith401WithoutAnyReservation() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 192 << 20); f.app.bodyBudget = budget
            let t = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
            for path in ["tenants/\(t)/key-rotation/objects/\(id)", "tenants/\(t)/forms/\(id)/entries/\(id)/hold"] {
                var h = HTTPHeaders(); h.contentType = .json; h.add(name: "Origin", value: AdminFixture.origin)
                try await f.app.test(.PUT, "admin/api/v1/\(path)", headers: h, body: body(40 * mib)) { r async throws in
                    XCTAssertEqual(r.status, .unauthorized, path)
                    XCTAssertEqual(self.problem(r), "unauthenticated")
                }
            }
            XCTAssertEqual(budget.granted, 0, "nothing was reserved for anonymous requests")
            XCTAssertEqual(budget.peak, 0)
            XCTAssertEqual(budget.refused, 0)
        }
    }

    func testAuthenticationOriginAndCSRFComeBeforeTheReservation() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(); f.app.bodyBudget = budget
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            let admin = try await f.login(user)
            let id = UUID().uuidString.lowercased()
            let path = "admin/api/v1/tenants/\(tenant)/key-rotation/objects/\(id)"
            // wrong Origin and missing CSRF token: 403, before any reservation
            try await f.app.test(.PUT, path, headers: admin.headers(origin: false), body: body(2 * mib)) { XCTAssertEqual($0.status, .forbidden) }
            try await f.app.test(.PUT, path, headers: admin.headers(csrf: false), body: body(2 * mib)) { XCTAssertEqual($0.status, .forbidden) }
            XCTAssertEqual(budget.granted, 0)
            // authenticated: the request is admitted (and then judged by the handler), the lease is returned afterwards
            try await f.app.test(.PUT, path, headers: admin.headers(), body: body(2 * mib)) { r async throws in
                XCTAssertNotEqual(r.status, .unauthorized); XCTAssertNotEqual(r.status, .serviceUnavailable); XCTAssertNotEqual(r.status, .payloadTooLarge)
            }
            XCTAssertEqual(budget.granted, 1)
            XCTAssertEqual(budget.peak, 2 * mib * BodyBudget.memoryFactor)
            XCTAssertEqual(budget.inFlight, 0, "the lease is given back after the response")
        }
    }

    func testAuthenticatedAdminBodiesNeedBudgetAndStayWithinTheRouteLimit() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 192 << 20); f.app.bodyBudget = budget
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            let admin = try await f.login(user)
            let path = "admin/api/v1/tenants/\(tenant)/key-rotation/objects/\(UUID().uuidString.lowercased())"
            // declared length above the route limit (64 MiB): 413 from the declared length, no reservation
            try await f.app.test(.PUT, path, headers: admin.headers(), body: body(65 * mib)) { r async throws in
                XCTAssertEqual(r.status, .payloadTooLarge); XCTAssertEqual(self.problem(r), "payload_too_large")
            }
            XCTAssertEqual(budget.granted, 0)
            // budget exhausted by other work: 503 + Retry-After, not read
            let busy = try XCTUnwrap(budget.reserve(bodyBytes: 60 * mib))
            try await f.app.test(.PUT, path, headers: admin.headers(), body: body(10 * mib)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.problem(r), "body_budget_exhausted")
                XCTAssertEqual(r.headers.first(name: "Retry-After"), "1")
            }
            XCTAssertEqual(budget.granted, 1, "only the occupying lease")
            busy.release()
            // the largest legitimate replacement (64 MiB) fits an empty budget and is admitted
            try await f.app.test(.PUT, path, headers: admin.headers(), body: body(64 * mib)) { r async throws in
                XCTAssertNotEqual(r.status, .serviceUnavailable); XCTAssertNotEqual(r.status, .payloadTooLarge); XCTAssertNotEqual(r.status, .unauthorized)
            }
            XCTAssertEqual(budget.inFlight, 0)
        }
    }

    func testRequestBudgetIsChargedOncePerRequest() async throws {
        try await AdminFixture.with { f in
            let root = try await f.account(), user = try await f.account(), tenant = try await f.customer()
            try await f.grant(user, "key.manage", customer: tenant, by: root)
            let admin = try await f.login(user)
            let path = "admin/api/v1/tenants/\(tenant)/key-rotation/objects/\(UUID().uuidString.lowercased())"
            try await f.app.test(.PUT, path, headers: admin.headers(), body: body(1024)) { _ in }
            struct C: Decodable { let c: Int }
            // gate and handler both ask for the budget: one count for the IP and one for the account, not two each
            let n = try await f.sql.raw("SELECT CAST(COALESCE(SUM(failures),0) AS SIGNED) AS c FROM auth_throttles WHERE scope = 'admin-route'").first(decoding: C.self)?.c
            XCTAssertEqual(n, 2)
        }
    }

    // MARK: ingest

    private func activeForm(_ f: AdminFixture) async throws -> UUID {
        let tenant = try await f.customer(), form = try await f.form(customer: tenant)
        try await f.sql.raw("UPDATE forms SET active = 1 WHERE id = \(bind: DB.bin(form))").run()
        return form
    }
    private func submitHeaders(type: String = "application/x-www-form-urlencoded") -> HTTPHeaders {
        var h = HTTPHeaders(); h.replaceOrAdd(name: .contentType, value: type)
        h.add(name: "X-Kubus-Timestamp", value: String(Int64(Date().timeIntervalSince1970)))
        h.add(name: "X-Kubus-Signature", value: Data(count: 64).base64EncodedString())
        return h
    }

    func testIngestPreChecksAndBudgetRunBeforeTheBodyIsRead() async throws {
        try await AdminFixture.with { f in
            let budget = BodyBudget(capacity: 192 << 20); f.app.bodyBudget = budget
            let form = try await activeForm(f)
            // unknown form, missing form, wrong type, missing signature headers: refused with the contract's status, nothing reserved
            try await f.app.test(.POST, "api/v2/submit/?f=\(UUID().uuidString.lowercased())", headers: submitHeaders(), body: body(30 * mib)) { XCTAssertEqual($0.status, .notFound) }
            try await f.app.test(.POST, "api/v2/submit/", headers: submitHeaders(), body: body(30 * mib)) { XCTAssertEqual($0.status, .unauthorized) }
            var noSig = HTTPHeaders(); noSig.contentType = .urlEncodedForm
            try await f.app.test(.POST, "api/v2/submit/?f=\(form.uuidString.lowercased())", headers: noSig, body: body(30 * mib)) { XCTAssertEqual($0.status, .forbidden) }
            try await f.app.test(.POST, "api/v2/submit/?f=\(form.uuidString.lowercased())", headers: HTTPHeaders([("X-Kubus-Timestamp", "1")]), body: body(30 * mib)) { XCTAssertEqual($0.status, .unsupportedMediaType) }
            XCTAssertEqual(budget.granted, 0, "no reservation, no buffering, for requests that fail the cheap pre-checks")
            // declared length above the ingest limit (32 MiB): 413 before the body
            try await f.app.test(.POST, "api/v2/submit/?f=\(form.uuidString.lowercased())", headers: submitHeaders(), body: body(33 * mib)) { r async throws in
                XCTAssertEqual(r.status, .payloadTooLarge); XCTAssertEqual(self.problem(r), "payload_too_large")
            }
            XCTAssertEqual(budget.granted, 0)
            // budget exhausted: 503 with its own code
            let busy = try XCTUnwrap(budget.reserve(bodyBytes: 60 * mib))
            try await f.app.test(.POST, "api/v2/submit/?f=\(form.uuidString.lowercased())", headers: submitHeaders(), body: body(10 * mib)) { r async throws in
                XCTAssertEqual(r.status, .serviceUnavailable); XCTAssertEqual(self.problem(r), "body_budget_exhausted"); XCTAssertEqual(r.headers.first(name: "Retry-After"), "1")
            }
            busy.release()
            // free budget: the body is admitted and then rejected by the signature check (the form has no SDK key), lease given back
            try await f.app.test(.POST, "api/v2/submit/?f=\(form.uuidString.lowercased())", headers: submitHeaders(), body: body(10 * mib)) { r async throws in
                XCTAssertNotEqual(r.status, .serviceUnavailable); XCTAssertNotEqual(r.status, .payloadTooLarge)
            }
            XCTAssertEqual(budget.inFlight, 0)
            XCTAssertEqual(budget.peak, 60 * mib * BodyBudget.memoryFactor, "only the occupying lease (180 MiB) was ever reserved at once; the admitted 10 MiB body came after its release")
        }
    }

    func testChunkedBodiesWithoutLengthReserveTheWorstCase() async throws {
        try await AdminFixture.with { f in
            let loop = f.app.eventLoopGroup.next()
            func request(_ h: HTTPHeaders) -> Request { Request(application: f.app, method: .POST, url: URI(path: "/"), headers: h, on: loop) }
            var chunked = HTTPHeaders(); chunked.replaceOrAdd(name: .transferEncoding, value: "chunked")
            XCTAssertEqual(try BodyBudgetGate.declaredBytes(request(chunked), maxBytes: 32 * mib), 32 * mib, "unknown length: worst case")
            XCTAssertEqual(try BodyBudgetGate.declaredBytes(request(HTTPHeaders()), maxBytes: 32 * mib), 0, "no length, no chunking: empty body")
            var sized = HTTPHeaders(); sized.replaceOrAdd(name: .contentLength, value: "1000")
            XCTAssertEqual(try BodyBudgetGate.declaredBytes(request(sized), maxBytes: 32 * mib), 1000)
            sized.replaceOrAdd(name: .contentLength, value: "33554433")
            XCTAssertThrowsError(try BodyBudgetGate.declaredBytes(request(sized), maxBytes: 32 * mib)) { XCTAssertTrue($0 is RequestBodyTooLarge) }
            sized.replaceOrAdd(name: .contentLength, value: "-5")
            XCTAssertThrowsError(try BodyBudgetGate.declaredBytes(request(sized), maxBytes: 32 * mib))
            // the worst case of one chunked ingest body (96 MiB) does not fit next to 100 MiB already in flight
            let budget = BodyBudget(capacity: 192 << 20)
            let busy = try XCTUnwrap(budget.reserve(bodyBytes: 34 * mib))
            XCTAssertNil(budget.reserve(bodyBytes: 32 * mib))
            busy.release()
            XCTAssertNotNil(budget.reserve(bodyBytes: 32 * mib))
        }
    }
}
