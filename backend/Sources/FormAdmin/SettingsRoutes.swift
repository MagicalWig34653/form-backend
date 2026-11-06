// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

enum SettingsRoutes {
    struct Snapshot: Encodable { let revision: String; let items: [SettingsRegistry.Resolved] }
    static func register(_ app: Application, guardian: AuthGuard, db: Database, now: @escaping @Sendable () -> Date) {
        let env = ProcessInfo.processInfo.environment
        for method in [HTTPMethod.GET, .PUT] {
            app.on(method, "admin", "api", "v1", "settings", body: .collect(maxSize: "32kb")) { req async throws -> Response in
                let s = try await guardian.requireAuthenticated(req, mutation: method == .PUT)
                try await guardian.budget(req)
                try await guardian.requireFreshAuthentication(s, now: now())
                let snapshot = try await db.transaction { conn -> Snapshot in
                    let sql = conn as! SQLDatabase
                    try await PermissionService(sql: sql).authorize(account: s.accountID!, "system.settings", on: .system)
                    let at = DB.time(now())
                    var revision = try await SystemSettings.lock(sql, at: at)
                    if method == .PUT {
                        struct Input: Decodable { let revision: String; let values: [String: String] }
                        guard let buffer = req.body.data else { throw Abort(.badRequest) }
                        do { _ = try JCS.parse(Data(buffer: buffer)) } catch { throw Abort(.badRequest) }
                        let input: Input = try FormAdmin.decodeStrict(req, allowed: ["revision", "values"])
                        guard input.revision == revision else { throw Abort(.conflict) }
                        guard !input.values.isEmpty else { throw Abort(.unprocessableEntity) }
                        for (key, value) in input.values {
                            guard let entry = SettingsRegistry.entries.first(where: { $0.key == key }), env[entry.envName] == nil else { throw Abort(.unprocessableEntity) }
                            do { try entry.validate(value) } catch { throw Abort(.unprocessableEntity) }
                        }
                        for (key, value) in input.values { try await SystemSettings.write(sql, key: key, value: value, at: at) }
                        // Validate coupled origin/RP settings before committing any member of the batch.
                        let merged = try await SystemSettings.environment(sql, env: env)
                        if let origin = merged["FORM_ADMIN_ORIGIN"], let rp = merged["FORM_RP_ID"], let host = URLComponents(string: origin)?.host {
                            guard host == rp || host.hasSuffix("." + rp) else { throw Abort(.unprocessableEntity) }
                        }
                        revision = UUID().uuidString.lowercased()
                        try await SystemSettings.write(sql, key: "_revision", value: revision, at: at)
                        let details = SettingsRegistry.auditDetails(keys: Array(input.values.keys))
                        try await sql.raw("INSERT INTO audit_events (id, actor_id, actor_kind, category, action_code, occurred_at, safe_details_json) VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(s.accountID!)), 'human', 'system', 'system.settings.update', \(bind: at), \(bind: details))").run()
                    }
                    let stored = try await SystemSettings.read(sql)
                    return Snapshot(revision: revision, items: try SettingsRegistry.entries.map { try SettingsRegistry.resolve($0, env: env, stored: stored) })
                }
                let response = try FormAdmin.json(.ok, snapshot)
                response.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return response
            }
        }
    }
}
