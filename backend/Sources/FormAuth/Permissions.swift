// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// What an action is aimed at. Derived from the DB ownership chain customer > form, never from request IDs alone.
public enum PermissionTarget: Sendable, Equatable {
    case system
    case customer(UUID)
    case form(customer: UUID, form: UUID)
}

/// Scope of one effective grant (contracts/auth/rechte.md).
public enum GrantScope: Sendable, Equatable {
    case system
    case customer(UUID)                       // all forms of the customer
    case form(customer: UUID, form: UUID)     // exactly this form

    public func covers(_ target: PermissionTarget) -> Bool {
        switch (self, target) {
        case (.system, _): return true
        case (.customer(let c), .customer(let t)): return c == t
        case (.customer(let c), .form(let t, _)): return c == t
        case (.form(let c, let f), .form(let tc, let tf)): return c == tc && f == tf
        default: return false
        }
    }

    /// Intersection of a group scope and an assignment scope; nil if empty.
    static func intersect(_ a: GrantScope, _ b: GrantScope) -> GrantScope? {
        switch (a, b) {
        case (.system, let x), (let x, .system): return x
        case (.customer(let c1), .customer(let c2)): return c1 == c2 ? a : nil
        case (.customer(let c1), .form(let c2, _)): return c1 == c2 ? b : nil
        case (.form(let c1, _), .customer(let c2)): return c1 == c2 ? a : nil
        case (.form(let c1, let f1), .form(let c2, let f2)): return c1 == c2 && f1 == f2 ? a : nil
        }
    }
}

public struct Grant: Sendable, Equatable {
    public let permission: String
    public let scope: GrantScope
    public init(permission: String, scope: GrantScope) { self.permission = permission; self.scope = scope }
}

/// Compiled-in permission catalog; the application never writes the table and refuses to start on a mismatch
/// (contracts/auth/p5b-ergaenzung.md E6).
public enum PermissionCatalog {
    public static let all: Set<String> = [
        "account.manage", "audit.read", "content.decrypt", "content.delete", "content.export", "content.hold",
        "content.read", "content.resend", "debug.export", "debug.plaintext", "debug.read", "domain.manage",
        "draft.export", "draft.write", "flow.approve", "flow.execute", "flow.resume", "form.create", "form.read",
        "identity.manage", "key.manage", "privacy.manage", "release.publish", "statistics.delete", "statistics.read",
        "migration.run", "system.manage", "system.settings", "test-target.manage", "test.run", "token.manage",
    ]

    public struct Mismatch: Error, Equatable { public let missingInDB: [String]; public let unknownInDB: [String] }

    public static func verify(_ sql: SQLDatabase) async throws {
        struct R: Decodable { let permission: String }
        let db = Set(try await sql.raw("SELECT permission FROM permission_catalog").all(decoding: R.self).map(\.permission))
        if db != all { throw Mismatch(missingInDB: all.subtracting(db).sorted(), unknownInDB: db.subtracting(all).sorted()) }
    }
}

/// One rights check for REST, MCP and UI: live from the DB on every call (no cached grants).
public struct PermissionService: Sendable {
    let sql: SQLDatabase
    public init(sql: SQLDatabase) { self.sql = sql }

    private struct AccountRow: Decodable { let active: Int }
    private struct Direct: Decodable { let permission: String; let scope_kind: String; let customer_id: Blob?; let form_id: Blob? }
    private struct Grouped: Decodable {
        let permission: String
        let a_kind: String; let a_cust: Blob?; let a_form: Blob?
        let g_kind: String; let g_cust: Blob?; let g_form: Blob?
    }

    private static func scope(_ kind: String, _ c: Blob?, _ f: Blob?) -> GrantScope? {
        switch kind {
        case "system": return .system
        case "customer":
            guard let cid = c.flatMap({ DB.uuid($0.data) }) else { return nil }
            if let fid = f.flatMap({ DB.uuid($0.data) }) { return .form(customer: cid, form: fid) }
            return .customer(cid)
        default: return nil
        }
    }

    /// All currently effective grants. Empty for an unknown or inactive account.
    public func grants(account: UUID) async throws -> [Grant] {
        let id = DB.bin(account)
        guard let acc = try await sql.raw("SELECT active FROM accounts WHERE id = \(bind: id)").first(decoding: AccountRow.self), acc.active == 1 else { return [] }
        var result: [Grant] = []
        for d in try await sql.raw("""
            SELECT permission, scope_kind, customer_id, form_id FROM permission_assignments
            WHERE account_id = \(bind: id) AND revoked_at IS NULL AND permission IS NOT NULL
            """).all(decoding: Direct.self) {
            if let s = Self.scope(d.scope_kind, d.customer_id, d.form_id), PermissionCatalog.all.contains(d.permission) {
                result.append(Grant(permission: d.permission, scope: s))
            }
        }
        for g in try await sql.raw("""
            SELECT r.permission AS permission, a.scope_kind AS a_kind, a.customer_id AS a_cust, a.form_id AS a_form,
                   g.scope_kind AS g_kind, g.customer_id AS g_cust, g.form_id AS g_form
            FROM permission_assignments a
            JOIN permission_groups g ON g.id = a.group_id AND g.revoked_at IS NULL
            JOIN permission_group_rights r ON r.group_id = g.id
            WHERE a.account_id = \(bind: id) AND a.revoked_at IS NULL
            """).all(decoding: Grouped.self) {
            if let a = Self.scope(g.a_kind, g.a_cust, g.a_form), let b = Self.scope(g.g_kind, g.g_cust, g.g_form),
               let s = GrantScope.intersect(a, b), PermissionCatalog.all.contains(g.permission) {
                result.append(Grant(permission: g.permission, scope: s))
            }
        }
        return result
    }

    public func can(account: UUID, _ permission: String, on target: PermissionTarget) async throws -> Bool {
        try await grants(account: account).contains { $0.permission == permission && $0.scope.covers(target) }
    }

    /// 404 if no grant of any right covers the target (existence is not revealed), 403 if covered but the action
    /// right is missing (VORGESCHLAGEN F7). `exists` is the caller's DB lookup of the resource.
    public func authorize(account: UUID, _ permission: String, on target: PermissionTarget, exists: Bool = true) async throws {
        precondition(PermissionCatalog.all.contains(permission), "unknown permission \(permission)")
        let grants = try await grants(account: account)
        guard exists, grants.contains(where: { $0.scope.covers(target) }) else { throw Abort(.notFound) }
        guard grants.contains(where: { $0.permission == permission && $0.scope.covers(target) }) else { throw Abort(.forbidden) }
    }
}
