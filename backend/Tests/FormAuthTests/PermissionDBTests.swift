// SPDX-License-Identifier: AGPL-3.0-only
import FormPersistence
import Foundation
import SQLKit
import Vapor
import XCTest
@testable import FormAuth

final class PermissionDBTests: XCTestCase {
    private struct World {
        let c1 = UUID(), c2 = UUID(), f1a = UUID(), f1b = UUID(), f2 = UUID()
    }

    private func seed(_ f: DBFixture) async throws -> World {
        let w = World()
        for c in [w.c1, w.c2] {
            try await f.sql.raw("INSERT INTO customers (id, name, state, created_at) VALUES (\(bind: DB.bin(c)), 'c', 'active', '2026-10-30 12:00:00.000000')").run()
        }
        for (form, c) in [(w.f1a, w.c1), (w.f1b, w.c1), (w.f2, w.c2)] {
            try await f.sql.raw("INSERT INTO forms (id, customer_id, name, active, created_at) VALUES (\(bind: DB.bin(form)), \(bind: DB.bin(c)), 'f', 1, '2026-10-30 12:00:00.000000')").run()
        }
        return w
    }

    private func grant(_ f: DBFixture, account: UUID, grantedBy: UUID, permission: String, kind: String, customer: UUID? = nil, form: UUID? = nil, revoked: Bool = false) async throws {
        try await f.sql.raw("""
            INSERT INTO permission_assignments (id, account_id, permission, scope_kind, customer_id, form_id, revision, granted_by, granted_at, revoked_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), \(bind: permission), \(bind: kind), \(bind: customer.map(DB.bin)), \(bind: form.map(DB.bin)), 1,
              \(bind: DB.bin(grantedBy)), '2026-10-30 12:00:00.000000', \(bind: revoked ? "2026-10-30 13:00:00.000000" : nil))
            """).run()
    }

    private func group(_ f: DBFixture, kind: String, customer: UUID?, form: UUID?, rights: [String], revoked: Bool = false) async throws -> UUID {
        let g = UUID()
        try await f.sql.raw("""
            INSERT INTO permission_groups (id, name, scope_kind, customer_id, form_id, revision, revoked_at)
            VALUES (\(bind: DB.bin(g)), 'g', \(bind: kind), \(bind: customer.map(DB.bin)), \(bind: form.map(DB.bin)), 1, \(bind: revoked ? "2026-10-30 13:00:00.000000" : nil))
            """).run()
        for r in rights { try await f.sql.raw("INSERT INTO permission_group_rights (group_id, permission) VALUES (\(bind: DB.bin(g)), \(bind: r))").run() }
        return g
    }

    private func assignGroup(_ f: DBFixture, account: UUID, group: UUID, grantedBy: UUID, kind: String, customer: UUID?, form: UUID?) async throws {
        try await f.sql.raw("""
            INSERT INTO permission_assignments (id, account_id, group_id, scope_kind, customer_id, form_id, revision, granted_by, granted_at)
            VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(account)), \(bind: DB.bin(group)), \(bind: kind), \(bind: customer.map(DB.bin)), \(bind: form.map(DB.bin)), 1,
              \(bind: DB.bin(grantedBy)), '2026-10-30 12:00:00.000000')
            """).run()
    }

    func testCatalogMatchesDatabase() async throws {
        try await DBFixture.with { f in try await PermissionCatalog.verify(f.sql) }
    }

    func testScopesDirectGrantsAndDenial() async throws {
        try await DBFixture.with { f in
            let w = try await seed(f)
            let admin = try await f.account(), user = try await f.account()
            let p = PermissionService(sql: f.sql)
            try await grant(f, account: user, grantedBy: admin, permission: "form.read", kind: "customer", customer: w.c1)
            try await grant(f, account: user, grantedBy: admin, permission: "draft.write", kind: "customer", customer: w.c1, form: w.f1a)
            try await grant(f, account: user, grantedBy: admin, permission: "release.publish", kind: "customer", customer: w.c1, revoked: true)
            let c1 = PermissionTarget.customer(w.c1)
            let f1a = PermissionTarget.form(customer: w.c1, form: w.f1a), f1b = PermissionTarget.form(customer: w.c1, form: w.f1b)
            let f2 = PermissionTarget.form(customer: w.c2, form: w.f2)
            var r = try await p.can(account: user, "form.read", on: f1a); XCTAssertTrue(r)
            r = try await p.can(account: user, "form.read", on: f1b); XCTAssertTrue(r)
            r = try await p.can(account: user, "form.read", on: f2); XCTAssertFalse(r)
            r = try await p.can(account: user, "draft.write", on: f1a); XCTAssertTrue(r)
            r = try await p.can(account: user, "draft.write", on: f1b); XCTAssertFalse(r)   // form scope is only this form
            r = try await p.can(account: user, "draft.write", on: c1); XCTAssertFalse(r)    // a form grant does not cover the customer
            r = try await p.can(account: user, "release.publish", on: f1a); XCTAssertFalse(r) // revoked
            r = try await p.can(account: user, "form.read", on: .system); XCTAssertFalse(r)
            // 404 without any covering grant, 403 with coverage but missing action right
            do { try await p.authorize(account: user, "form.read", on: f2); XCTFail() } catch let e as AbortError { XCTAssertEqual(e.status, .notFound) }
            do { try await p.authorize(account: user, "release.publish", on: f1a); XCTFail() } catch let e as AbortError { XCTAssertEqual(e.status, .forbidden) }
            do { try await p.authorize(account: user, "form.read", on: f1a, exists: false); XCTFail() } catch let e as AbortError { XCTAssertEqual(e.status, .notFound) }
            try await p.authorize(account: user, "form.read", on: f1a)
        }
    }

    func testGroupGrantsUseIntersectionOfGroupAndAssignmentScope() async throws {
        try await DBFixture.with { f in
            let w = try await seed(f)
            let admin = try await f.account(), user = try await f.account()
            let p = PermissionService(sql: f.sql)
            let g = try await group(f, kind: "customer", customer: w.c1, form: nil, rights: ["content.read", "statistics.read"])
            // assignment narrower than the group: only form f1a
            try await assignGroup(f, account: user, group: g, grantedBy: admin, kind: "customer", customer: w.c1, form: w.f1a)
            var r = try await p.can(account: user, "content.read", on: .form(customer: w.c1, form: w.f1a)); XCTAssertTrue(r)
            r = try await p.can(account: user, "content.read", on: .form(customer: w.c1, form: w.f1b)); XCTAssertFalse(r)
            // assignment in a foreign customer: empty intersection
            let other = try await f.account()
            try await assignGroup(f, account: other, group: g, grantedBy: admin, kind: "customer", customer: w.c2, form: nil)
            let gs = try await p.grants(account: other)
            XCTAssertTrue(gs.isEmpty)
            // a system assignment of a customer group stays inside the group's customer
            let sys = try await f.account()
            try await assignGroup(f, account: sys, group: g, grantedBy: admin, kind: "system", customer: nil, form: nil)
            r = try await p.can(account: sys, "content.read", on: .customer(w.c1)); XCTAssertTrue(r)
            r = try await p.can(account: sys, "content.read", on: .customer(w.c2)); XCTAssertFalse(r)
        }
    }

    func testRevokedGroupAndInactiveAccountGrantNothing() async throws {
        try await DBFixture.with { f in
            let w = try await seed(f)
            let admin = try await f.account(), user = try await f.account()
            let p = PermissionService(sql: f.sql)
            let g = try await group(f, kind: "customer", customer: w.c1, form: nil, rights: ["content.read"], revoked: true)
            try await assignGroup(f, account: user, group: g, grantedBy: admin, kind: "customer", customer: w.c1, form: nil)
            var gs = try await p.grants(account: user); XCTAssertTrue(gs.isEmpty)
            let live = try await group(f, kind: "customer", customer: w.c1, form: nil, rights: ["content.read"])
            try await assignGroup(f, account: user, group: live, grantedBy: admin, kind: "customer", customer: w.c1, form: nil)
            gs = try await p.grants(account: user); XCTAssertEqual(gs.count, 1)
            try await f.sql.raw("UPDATE accounts SET active = 0 WHERE id = \(bind: DB.bin(user))").run()
            gs = try await p.grants(account: user); XCTAssertTrue(gs.isEmpty)
            gs = try await p.grants(account: UUID()); XCTAssertTrue(gs.isEmpty)
        }
    }

    func testRevocationTakesEffectOnTheNextCheck() async throws {
        try await DBFixture.with { f in
            let w = try await seed(f)
            let admin = try await f.account(), user = try await f.account()
            let p = PermissionService(sql: f.sql)
            try await grant(f, account: user, grantedBy: admin, permission: "form.read", kind: "system")
            var r = try await p.can(account: user, "form.read", on: .form(customer: w.c2, form: w.f2)); XCTAssertTrue(r)
            try await f.sql.raw("UPDATE permission_assignments SET revoked_at = '2026-10-30 14:00:00.000000' WHERE account_id = \(bind: DB.bin(user))").run()
            r = try await p.can(account: user, "form.read", on: .form(customer: w.c2, form: w.f2)); XCTAssertFalse(r)
        }
    }

    func testPureScopeIntersection() {
        let c = UUID(), d = UUID(), f = UUID()
        XCTAssertEqual(GrantScope.intersect(.system, .customer(c)), .customer(c))
        XCTAssertEqual(GrantScope.intersect(.customer(c), .system), .customer(c))
        XCTAssertNil(GrantScope.intersect(.customer(c), .customer(d)))
        XCTAssertEqual(GrantScope.intersect(.customer(c), .form(customer: c, form: f)), .form(customer: c, form: f))
        XCTAssertNil(GrantScope.intersect(.form(customer: c, form: f), .form(customer: c, form: UUID())))
    }
}
