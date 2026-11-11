// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Fluent
import FluentMySQLDriver
import Foundation
import NIOSSL
import SQLKit
import Vapor

public enum Persistence {
    /// Pool size per event loop when the caller does not fix one. Every pinned service (`app.db` captured at boot) draws
    /// from the pool of one loop, and the lock-holding schedulers (mail, auth, flow, webhooks, storage, ops, deploy,
    /// erasure, migration) each keep one connection while asking for a second. With 4 per loop and few cores these
    /// holders exhausted the pool and every waiter ran into the 10 s pool timeout. Small hosts get a pool well above
    /// the number of such holders; the total per replica stays at 32 up to 8 loops and at the former 4 per loop above.
    public static func defaultMaxConnectionsPerEventLoop(eventLoops: Int) -> Int {
        max(4, 32 / max(1, eventLoops))
    }

    /// Registers the MariaDB/MySQL connection pool as the default database. No Fluent migrations.
    public static func configure(_ app: Application, _ config: AppConfig, maxConnectionsPerEventLoop: Int? = nil) {
        let loops = app.eventLoopGroup.makeIterator().reduce(0) { n, _ in n + 1 }
        let maxConnectionsPerEventLoop = maxConnectionsPerEventLoop ?? defaultMaxConnectionsPerEventLoop(eventLoops: loops)
        var tls: TLSConfiguration? = TLSConfiguration.makeClientConfiguration()
        if config.dbTLS == .disable { tls = nil }
        let cfg = MySQLConfiguration(
            hostname: config.dbHost, port: config.dbPort, username: config.dbUser,
            password: config.dbPassword, database: config.dbName, tlsConfiguration: tls)
        app.databases.use(.mysql(configuration: cfg, maxConnectionsPerEventLoop: maxConnectionsPerEventLoop), as: .mysql)
    }

    /// Raw SQL access for the runner/readiness probe.
    public static func sql(_ app: Application) -> SQLDatabase {
        app.db(.mysql) as! SQLDatabase
    }

    /// True once the migration runner has recorded the schema. Replicas that start before `migrate` finished report
    /// not-ready, so an orchestrator (Swarm, Kubernetes) does not route traffic to them.
    public static func schemaApplied(_ app: Application) async -> Bool {
        struct R: Decodable { let n: Int }
        return ((try? await sql(app).raw("SELECT COUNT(*) AS n FROM schema_migrations").first(decoding: R.self))?.n ?? 0) > 0
    }

    /// Readiness: a single `SELECT 1` with a hard timeout. Concurrent probes share one in-flight check so an
    /// unauthenticated endpoint cannot occupy more than one pool connection. Details are never exposed.
    public static func ping(_ app: Application, timeoutSeconds: Double = 2) async -> Bool {
        let gate = app.storage[ReadinessGateKey.self] ?? {
            let g = ReadinessGate(); app.storage[ReadinessGateKey.self] = g; return g
        }()
        let db = sql(app)
        return await gate.check {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                let once = ResumeOnce(cont)
                Task { once.resume((try? await db.raw("SELECT 1").run()) != nil) }
                Task { try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000)); once.resume(false) }
            }
        }
    }
}

private struct ReadinessGateKey: StorageKey { typealias Value = ReadinessGate }

private actor ReadinessGate {
    private var current: Task<Bool, Never>?
    func check(_ probe: @escaping @Sendable () async -> Bool) async -> Bool {
        if let t = current { return await t.value }
        let t = Task { await probe() }
        current = t
        let r = await t.value
        current = nil
        return r
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Bool, Never>?
    init(_ c: CheckedContinuation<Bool, Never>) { cont = c }
    func resume(_ v: Bool) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(returning: v)
    }
}
