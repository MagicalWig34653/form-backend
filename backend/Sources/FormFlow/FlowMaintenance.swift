// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FluentMySQLDriver
import Foundation
import SQLKit
import Vapor

/// Recovery only marks runs for a human. It never schedules plaintext or retries transports.
public struct FlowMaintenance: LifecycleHandler {
    public init() {}
    public static func runOnce(db: Database, now: Date = Date()) async throws {
        struct Lock: Decodable { let acquired: Int? }
        try await (db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK('form_flow_maintenance',0) AS acquired").first(decoding: Lock.self)?.acquired == 1 else { return }
            do {
                try await FlowStore(db: db).expireWaiting(now: now)
                _ = try await FlowStore(db: db).recoverExpired(now: now)
                try await FlowDebugStore(db: db).purge(now: now)
                try await session.raw("SELECT RELEASE_LOCK('form_flow_maintenance')").run()
            } catch {
                try? await session.raw("SELECT RELEASE_LOCK('form_flow_maintenance')").run()
                throw error
            }
        }
    }
    public func didBoot(_ app: Application) throws {
        let db = app.db(.mysql), logger = app.logger
        app.storage[FlowMaintenanceKey.self] = Task.detached {
            while !Task.isCancelled {
                do { try await Self.runOnce(db: db) }
                catch { logger.warning("flow maintenance failed", metadata: ["type": "\(type(of: error))"]) }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }
    public func shutdown(_ app: Application) { app.storage[FlowMaintenanceKey.self]?.cancel() }
}
private struct FlowMaintenanceKey: StorageKey { typealias Value = Task<Void, Never> }
