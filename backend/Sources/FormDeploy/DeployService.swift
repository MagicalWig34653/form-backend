// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormCore
import FormMail
import FormPersistence
import Foundation
import SQLKit
import Vapor

public protocol DeploySecretProvider: Sendable { func secret(ref: String, on session: SQLDatabase) async throws -> String? }

/// Runs SDK installs / rollbacks for one target (ADR 0011): loads the target and its connection, takes a cross-replica lock, performs
/// the FTP work, records the run and the new state. Used by the admin routes (manual) and the scheduler (automatic, optional per target).
public struct DeployService: Sendable {
    public enum Action: String, Sendable { case install, rollback }
    public enum Trigger: String, Sendable { case manual, auto }
    public struct Result: Sendable, Equatable { public let ok: Bool; public let from: String?; public let to: String?; public let errorCode: String? }
    public struct Failure: Error, Equatable { public let code: String; public init(_ c: String) { code = c } }

    let db: Database
    let secrets: any DeploySecretProvider
    let bundle: @Sendable () throws -> SDKBundle
    let allowedNets: [CIDR]
    let allowInsecure: Bool
    let now: @Sendable () -> Date
    let logger: Logger

    public init(db: Database, secrets: any DeploySecretProvider, bundle: @escaping @Sendable () throws -> SDKBundle, allowedNets: [CIDR], allowInsecure: Bool,
                logger: Logger, now: @escaping @Sendable () -> Date = { Date() }) {
        self.db = db; self.secrets = secrets; self.bundle = bundle; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.logger = logger; self.now = now
    }

    private struct TargetRow: Decodable {
        let connection_id: Blob; let remote_dir: String; let auto_update: Int; let installed_version: String?; let previous_version: String?
        let kind: String; let safe_config_json: String; let credential_ref: String?; let enabled: Int
    }

    public static func ftpConfig(_ cfg: [String: Any], password: String, allowInsecure: Bool) throws -> FTPConfig {
        guard let host = cfg["host"] as? String, !host.isEmpty, host.utf8.count <= 253, let user = cfg["username"] as? String, !user.isEmpty,
              let port = (cfg["port"] as? Int) ?? 21 as Int?, (1...65535).contains(port),
              let sec = FTPConfig.Security(rawValue: (cfg["security"] as? String) ?? "explicit-tls") else { throw Failure("connection_invalid") }
        if sec == .plain && !allowInsecure { throw Failure("insecure_not_allowed") }
        let verify = (cfg["verifyCertificate"] as? Bool) ?? true
        if !verify && !allowInsecure { throw Failure("insecure_not_allowed") }   // certificate checks are only switchable together with the development release
        return FTPConfig(host: host, port: port, security: sec, username: user, password: password, verifyCertificate: verify)
    }

    public static func sftpConfig(_ cfg: [String: Any], password: String) throws -> SFTPConfig {
        guard let host = cfg["host"] as? String, !host.isEmpty, host.utf8.count <= 253, let user = cfg["username"] as? String, !user.isEmpty,
              let fp = cfg["hostKeySha256"] as? String, SSHHostKey.isValid(fp) else { throw Failure("connection_invalid") }
        let port = (cfg["port"] as? Int) ?? 22
        guard (1...65535).contains(port) else { throw Failure("connection_invalid") }
        return SFTPConfig(host: host, port: port, username: user, password: password, hostKeySHA256: fp)
    }

    /// Runs the action; always records a deployment row. `actor` nil = service.
    @discardableResult
    public func run(customer: UUID, form: UUID, action: Action, trigger: Trigger, actor: UUID?) async throws -> Result {
        try await (db as! SQLDatabase).withSession { session in
            try await self.run(on: session, customer: customer, form: form, action: action, trigger: trigger, actor: actor)
        }
    }

    // All work under a named lock must reuse its session, including nested scheduler runs and secret reads.
    // Acquiring from the pool here can deadlock when the lock holders exhaust that pool.
    private func run(on session: SQLDatabase, customer: UUID, form: UUID, action: Action, trigger: Trigger, actor: UUID?) async throws -> Result {
        let started = now()
        let lockName = "form_sdk_deploy_" + form.uuidString.lowercased().prefix(30)
        struct L: Decodable { let l: Int? }
        guard try await session.raw("SELECT GET_LOCK(\(literal: String(lockName)), 0) AS l").first(decoding: L.self)?.l == 1 else { throw Failure("busy") }
        let release = { _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: String(lockName)))").run() }
        do { let r = try await self.locked(session, customer: customer, form: form, action: action, trigger: trigger, actor: actor, started: started); await release(); return r }
        catch { await release(); throw error }
    }

    private func locked(_ session: SQLDatabase, customer: UUID, form: UUID, action: Action, trigger: Trigger, actor: UUID?, started: Date) async throws -> Result {
        do {
            guard let t = try await session.raw("""
                SELECT t.connection_id AS connection_id, t.remote_dir AS remote_dir, t.auto_update AS auto_update, t.installed_version AS installed_version,
                  t.previous_version AS previous_version, c.kind AS kind, c.safe_config_json AS safe_config_json, c.credential_ref AS credential_ref, c.enabled AS enabled
                FROM sdk_targets t JOIN connections c ON c.id = t.connection_id
                WHERE t.customer_id = \(bind: DB.bin(customer)) AND t.form_id = \(bind: DB.bin(form))
                """).first(decoding: TargetRow.self) else { throw Failure("no_target") }
            if trigger == .auto && t.auto_update != 1 { throw Failure("auto_disabled") }   // re-checked under the lock
            var to: String? = nil, errorCode: String? = nil, newInstalled = t.installed_version, newPrev = t.previous_version
            if action == .install { to = try? bundle().version }   // known before any network I/O, so a failure is attributed to this version
            do {
                guard ["ftp", "sftp"].contains(t.kind), t.enabled == 1, let ref = t.credential_ref, let pw = try await secrets.secret(ref: ref, on: session),
                      let cfg = (try? JSONSerialization.jsonObject(with: Data(t.safe_config_json.utf8))) as? [String: Any] else { throw Failure("connection_invalid") }
                let client: any RemoteFileClient = t.kind == "sftp"
                    ? SFTPClient(config: try Self.sftpConfig(cfg, password: pw), allowedNets: allowedNets)
                    : FTPClient(config: try Self.ftpConfig(cfg, password: pw, allowInsecure: allowInsecure), allowedNets: allowedNets, allowInsecure: allowInsecure)
                let deployer = SDKDeployer(client: client)
                do {
                    try await client.connect()
                    switch action {
                    case .install:
                        let b = try bundle()
                        to = b.version
                        if case .installed(let v, _) = try await deployer.install(b, to: t.remote_dir) {
                            newPrev = t.installed_version; newInstalled = v
                        }
                    case .rollback:
                        if case .rolledBack(let v) = try await deployer.rollback(t.remote_dir) {
                            to = v; newPrev = t.installed_version; newInstalled = v
                        }
                    }
                    await client.close()
                } catch { await client.close(); throw error }
            } catch let e as FTPError { errorCode = e.code } catch let e as Failure { errorCode = e.code } catch let e as SDKBundle.Failure { errorCode = "bundle_\(e)".prefix(40).description } catch { errorCode = "internal" }
            let finished = now()
            let ok = errorCode == nil
            try await session.raw("""
                INSERT INTO sdk_deployments (id, customer_id, form_id, action, trigger_kind, from_version, to_version, result, error_code, actor_id, started_at, finished_at)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(customer)), \(bind: DB.bin(form)), \(bind: action.rawValue), \(bind: trigger.rawValue), \(bind: t.installed_version),
                  \(bind: to), \(bind: ok ? "ok" : "failed"), \(bind: errorCode), \(bind: actor.map(DB.bin)), \(bind: DB.time(started)), \(bind: DB.time(finished)))
                """).run()
            try await session.raw("""
                UPDATE sdk_targets SET installed_version = \(bind: newInstalled), previous_version = \(bind: newPrev), last_result = \(bind: action == .rollback && ok ? "rolled_back" : ok ? "ok" : errorCode),
                  last_attempt_version = \(bind: action == .install ? to : (ok ? t.installed_version : nil)), updated_at = \(bind: DB.time(finished))
                WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form))
                """).run()
            logger.info("sdk deployment", metadata: ["form": "\(form.uuidString.lowercased())", "action": "\(action.rawValue)", "trigger": "\(trigger.rawValue)", "result": "\(ok ? "ok" : errorCode ?? "failed")"])
            return Result(ok: ok, from: t.installed_version, to: ok ? newInstalled : to, errorCode: errorCode)
        }
    }

    /// Targets with `auto_update` that are installed, older than the shipped SDK and not yet attempted for this version. Never installs
    /// a first time, never downgrades, never retries the same version after a failure.
    public func runAutomaticUpdates() async throws -> Int {
        try await (db as! SQLDatabase).withSession { try await self.runAutomaticUpdates(on: $0) }
    }

    fileprivate func runAutomaticUpdates(on session: SQLDatabase) async throws -> Int {
        guard let b = try? bundle() else { return 0 }
        struct R: Decodable { let customer_id: Blob; let form_id: Blob; let installed_version: String?; let last_attempt_version: String?; let last_result: String? }
        let due = try await session.raw("""
            SELECT customer_id, form_id, installed_version, last_attempt_version, last_result FROM sdk_targets WHERE auto_update = 1 AND installed_version IS NOT NULL
            """).all(decoding: R.self)
        var ran = 0
        for r in due {
            guard let c = DB.uuid(r.customer_id.data), let f = DB.uuid(r.form_id.data), let v = r.installed_version,
                  SDKBundle.compare(b.version, v) > 0, !(r.last_attempt_version == b.version && r.last_result != "ok") else { continue }   // a failed attempt for this version is not repeated
            _ = try? await run(on: session, customer: c, form: f, action: .install, trigger: .auto, actor: nil)
            ran += 1
        }
        return ran
    }
}

/// Checks for automatic SDK updates periodically; the named lock lets only one replica run a round at a time.
public struct DeployScheduler: LifecycleHandler {
    let service: DeployService
    let interval: TimeInterval
    public static let lockName = "form_sdk_auto_update"
    public init(service: DeployService, interval: TimeInterval = 600) { self.service = service; self.interval = interval }

    public static func runOnce(_ service: DeployService) async throws -> Int? {
        struct L: Decodable { let l: Int? }
        return try await (service.db as! SQLDatabase).withSession { session in
            guard try await session.raw("SELECT GET_LOCK(\(literal: lockName), 0) AS l").first(decoding: L.self)?.l == 1 else { return nil }
            do {
                let n = try await service.runAutomaticUpdates(on: session)
                _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run()
                return n
            } catch { _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lockName))").run(); throw error }
        }
    }

    public func didBoot(_ application: Application) throws {
        let s = service, i = interval
        application.eventLoopGroup.next().scheduleRepeatedAsyncTask(initialDelay: .seconds(60), delay: .seconds(Int64(i))) { task in
            let p = application.eventLoopGroup.next().makePromise(of: Void.self)
            Task { _ = try? await DeployScheduler.runOnce(s); p.succeed(()) }
            return p.futureResult
        }
    }
}
