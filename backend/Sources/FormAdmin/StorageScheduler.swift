// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormPersistence
import FormStorage
import Foundation
import SQLKit
import Vapor

/// Bounded recovery pass: failed/prepared uploads, orphaned references, then interrupted submission deletion.
public enum StorageMaintenance {
    public static func run(service: StorageService) async throws {
        let sql = service.db as! SQLDatabase
        struct L: Decodable { let l: Int? }
        try await sql.withSession { session in
            guard try await session.raw("SELECT GET_LOCK('form_storage', 0) AS l").first(decoding: L.self)?.l == 1 else { return }
            do {
                try await service.flush()
                struct R: Decodable { let submission_id: Blob; let customer_id: Blob; let form_id: Blob }
                let rows = try await sql.raw("SELECT DISTINCT submission_id, customer_id, form_id FROM stored_objects WHERE state = 'deleting' AND submission_id IS NOT NULL LIMIT 100").all(decoding: R.self)
                for r in rows {
                    guard let s = DB.uuid(r.submission_id.data), let c = DB.uuid(r.customer_id.data), let f = DB.uuid(r.form_id.data) else { continue }
                    _ = try await service.db.transaction { conn in
                        try await SubmissionEraser.erase(conn as! SQLDatabase, tenant: c, form: f, ids: [s], reason: "storage-retry", actor: nil, now: Date(), storage: service)
                    }
                }
                try await service.cleanOrphans()
                _ = try? await session.raw("SELECT RELEASE_LOCK('form_storage')").run()
            } catch {
                _ = try? await session.raw("SELECT RELEASE_LOCK('form_storage')").run()
                throw error
            }
        }
    }
}

public struct StorageScheduler: LifecycleHandler {
    let service: StorageService
    public init(service: StorageService) { self.service = service }
    public func didBoot(_ app: Application) throws {
        let service = service, logger = app.logger
        app.storage[StorageTaskKey.self] = Task {
            while !Task.isCancelled {
                do { try await StorageMaintenance.run(service: service) }
                catch { logger.warning("storage maintenance failed", metadata: ["type": "\(type(of: error))"]) }
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
    public func shutdown(_ app: Application) { app.storage[StorageTaskKey.self]?.cancel() }
}
private struct StorageTaskKey: StorageKey { typealias Value = Task<Void, Never> }
