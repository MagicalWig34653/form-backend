// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
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
        var last_result: String?; let target_revision: Int; let run_phase: String?; let run_action: String?; let run_trigger: String?; let run_started_at: Date?
        let kind: String; let safe_config_json: String; let credential_ref: String?; let enabled: Int
    }

    // MARK: locks (ADR 0042, review Astra 2 M1)

    /// One run per form at a time; a target change of that form waits for it.
    public static func formLockName(_ form: UUID) -> String { "form_sdk_deploy_" + form.uuidString.lowercased().prefix(30) }
    /// The physical account behind a connection: host and user name (protocol and port do not matter, FTP and SFTP of one account
    /// usually share the file system). Two connection records to the same account share this identity.
    public static func accountIdentity(configJSON: String) -> String {
        let cfg = ((try? JSONSerialization.jsonObject(with: Data(configJSON.utf8))) as? [String: Any]) ?? [:]
        var host = ((cfg["host"] as? String) ?? "").lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let id = "\(host)|\((cfg["username"] as? String) ?? "")"
        return SHA256.hash(data: Data(id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
    /// Serialises all runs on one account (a fixed staging name per target is then safe as overlapping targets are refused).
    public static func accountLockName(configJSON: String) -> String { "form_sdk_acct_" + accountIdentity(configJSON: configJSON) }
    /// Serialises target changes on one account, so two forms cannot claim overlapping paths at the same time.
    public static func targetChangeLockName(configJSON: String) -> String { "form_sdk_tchg_" + accountIdentity(configJSON: configJSON) }

    // MARK: open runs (ADR 0042, review Astra 2 M2)

    /// Closes a run that is still recorded as open although the caller holds the form lock: its process died (MariaDB released the
    /// lock with the session). Writes `interrupted` to the history and clears the run in ONE transaction. Only a crash in `swap`
    /// leaves the remote state unclear: then the target is `repair_required` and no version is claimed. In `connect`/`upload` only
    /// `.staging` was touched, live and `.prev` are as recorded. Returns true if the target now needs a repair.
    @discardableResult
    public static func closeOpenRun(_ session: SQLDatabase, customer: UUID, form: UUID, now: Date, logger: Logger) async throws -> Bool {
        struct O: Decodable { let run_phase: String?; let run_action: String?; let run_trigger: String?; let run_started_at: Date?; let installed_version: String? }
        try await session.raw("START TRANSACTION").run()
        do {
            guard let o = try await session.raw("""
                SELECT run_phase, run_action, run_trigger, run_started_at, installed_version FROM sdk_targets
                WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) FOR UPDATE
                """).first(decoding: O.self), let phase = o.run_phase else { try await session.raw("COMMIT").run(); return false }
            let unclear = phase == "swap"
            try await session.raw("""
                INSERT INTO sdk_deployments (id, customer_id, form_id, action, trigger_kind, from_version, to_version, result, error_code, actor_id, started_at, finished_at)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(customer)), \(bind: DB.bin(form)), \(bind: o.run_action ?? "install"), \(bind: o.run_trigger ?? "manual"),
                  \(bind: o.installed_version), NULL, 'failed', 'interrupted', NULL, \(bind: DB.time(o.run_started_at ?? now)), \(bind: DB.time(now)))
                """).run()
            if unclear {
                try await session.raw("""
                    UPDATE sdk_targets SET last_result = 'repair_required', installed_version = NULL, previous_version = NULL,
                      run_phase = NULL, run_action = NULL, run_trigger = NULL, run_started_at = NULL
                    WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form))
                    """).run()
            } else {
                try await session.raw("""
                    UPDATE sdk_targets SET last_result = IF(last_result = 'repair_required', last_result, 'interrupted'),
                      run_phase = NULL, run_action = NULL, run_trigger = NULL, run_started_at = NULL
                    WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form))
                    """).run()
            }
            try await session.raw("COMMIT").run()
            logger.warning("sdk deployment interrupted earlier", metadata: ["form": "\(form.uuidString.lowercased())", "phase": "\(phase)", "repair": "\(unclear)"])
            return unclear
        } catch { try? await session.raw("ROLLBACK").run(); throw error }
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
        let lockName = Self.formLockName(form)
        struct L: Decodable { let l: Int? }
        guard try await session.raw("SELECT GET_LOCK(\(literal: String(lockName)), 0) AS l").first(decoding: L.self)?.l == 1 else { throw Failure("busy") }
        let release = { _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: String(lockName)))").run() }
        do { let r = try await self.locked(session, customer: customer, form: form, action: action, trigger: trigger, actor: actor, started: started); await release(); return r }
        catch { await release(); throw error }
    }

    private static func targetQuery(customer: UUID, form: UUID) -> SQLQueryString {
        """
        SELECT t.connection_id AS connection_id, t.remote_dir AS remote_dir, t.auto_update AS auto_update, t.installed_version AS installed_version,
          t.previous_version AS previous_version, t.last_result AS last_result, t.target_revision AS target_revision, t.run_phase AS run_phase,
          t.run_action AS run_action, t.run_trigger AS run_trigger, t.run_started_at AS run_started_at,
          c.kind AS kind, c.safe_config_json AS safe_config_json, c.credential_ref AS credential_ref, c.enabled AS enabled
        FROM sdk_targets t JOIN connections c ON c.id = t.connection_id
        WHERE t.customer_id = \(bind: DB.bin(customer)) AND t.form_id = \(bind: DB.bin(form))
        """
    }

    private func locked(_ session: SQLDatabase, customer: UUID, form: UUID, action: Action, trigger: Trigger, actor: UUID?, started: Date) async throws -> Result {
        guard var t = try await session.raw(Self.targetQuery(customer: customer, form: form)).first(decoding: TargetRow.self) else { throw Failure("no_target") }
        // A run that is still open while we hold the form lock never finished: its process died (review Astra 2 M2).
        if t.run_phase != nil {
            try await Self.closeOpenRun(session, customer: customer, form: form, now: now(), logger: logger)
            guard let fresh = try await session.raw(Self.targetQuery(customer: customer, form: form)).first(decoding: TargetRow.self) else { throw Failure("no_target") }
            t = fresh
        }
        if trigger == .auto && t.auto_update != 1 { throw Failure("auto_disabled") }   // re-checked under the lock
        if trigger == .auto && t.last_result == "repair_required" { throw Failure("repair_required") }   // only a manual run repairs
        // one run per physical account (review Astra 2 M1)
        let accountLock = Self.accountLockName(configJSON: t.safe_config_json)
        struct L: Decodable { let l: Int? }
        guard try await session.raw("SELECT GET_LOCK(\(literal: accountLock), 0) AS l").first(decoding: L.self)?.l == 1 else { throw Failure("busy") }
        do {
            let r = try await work(session, t, customer: customer, form: form, action: action, trigger: trigger, actor: actor, started: started)
            _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: accountLock))").run()
            return r
        } catch { _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: accountLock))").run(); throw error }
    }

    private func work(_ session: SQLDatabase, _ t: TargetRow, customer: UUID, form: UUID, action: Action, trigger: Trigger, actor: UUID?, started: Date) async throws -> Result {
        let rev = t.target_revision
        var to: String? = nil, errorCode: String? = nil, newInstalled = t.installed_version, newPrev = t.previous_version
        if action == .install { to = try? bundle().version }   // known before any network I/O, so a failure is attributed to this version
        // the run is persisted BEFORE any remote change; each phase is written before it starts (review Astra 2 M2)
        try await session.raw("""
            UPDATE sdk_targets SET run_phase = 'connect', run_action = \(bind: action.rawValue), run_trigger = \(bind: trigger.rawValue), run_started_at = \(bind: DB.time(started))
            WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND target_revision = \(bind: rev)
            """).run()
        let reached = PhaseBox()
        let phase: SDKDeployer.Phase = { p in
            reached.set(p)
            try await session.raw("""
                UPDATE sdk_targets SET run_phase = \(bind: p) WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND target_revision = \(bind: rev)
                """).run()
        }
        do {
            guard ["ftp", "sftp"].contains(t.kind), t.enabled == 1, let ref = t.credential_ref, let pw = try await secrets.secret(ref: ref, on: session),
                  let cfg = (try? JSONSerialization.jsonObject(with: Data(t.safe_config_json.utf8))) as? [String: Any] else { throw Failure("connection_invalid") }
            let client: any RemoteFileClient = t.kind == "sftp"
                ? SFTPClient(config: try Self.sftpConfig(cfg, password: pw), allowedNets: allowedNets)
                : FTPClient(config: try Self.ftpConfig(cfg, password: pw, allowInsecure: allowInsecure), allowedNets: allowedNets, allowInsecure: allowInsecure)
            let deployer = SDKDeployer(client: client, phase: phase)
            do {
                try await client.connect()
                switch action {
                case .install:
                    let b = try bundle()
                    to = b.version
                    switch try await deployer.install(b, to: t.remote_dir) {
                    case .installed(let v, let prev), .unchanged(let v, let prev): newPrev = prev; newInstalled = v   // as found on the server
                    case .rolledBack: break
                    }
                case .rollback:
                    if case .rolledBack(let v) = try await deployer.rollback(t.remote_dir) {
                        to = v; newPrev = t.installed_version; newInstalled = v
                    }
                }
                await client.close()
            } catch { await client.close(); throw error }
        } catch let e as FTPError { errorCode = e.code } catch let e as Failure { errorCode = e.code } catch let e as SDKBundle.Failure { errorCode = "bundle_\(e)".prefix(40).description } catch { errorCode = "internal" }
        if errorCode == "repair_required" { newInstalled = nil; newPrev = nil }   // the remote state is unclear: nothing is claimed
        // a failed install that reached the swap had already removed the old .prev (or moved an unreadable live there): not claimed
        else if errorCode != nil && action == .install && reached.value == "swap" { newPrev = nil }
        let finished = now()
        let ok = errorCode == nil
        // a failed run never clears an earlier repair_required; only a successful (manual) run does
        let lastResult = ok ? (action == .rollback ? "rolled_back" : "ok") : (t.last_result == "repair_required" ? "repair_required" : errorCode)
        // history and target state in ONE transaction: a crash in between can neither leave an ok row next to an open run nor log twice
        try await session.raw("START TRANSACTION").run()
        do {
            try await session.raw("""
                INSERT INTO sdk_deployments (id, customer_id, form_id, action, trigger_kind, from_version, to_version, result, error_code, actor_id, started_at, finished_at)
                VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(customer)), \(bind: DB.bin(form)), \(bind: action.rawValue), \(bind: trigger.rawValue), \(bind: t.installed_version),
                  \(bind: to), \(bind: ok ? "ok" : "failed"), \(bind: errorCode), \(bind: actor.map(DB.bin)), \(bind: DB.time(started)), \(bind: DB.time(finished)))
                """).run()
            // only for the target revision this run started on (review Astra 2 M1); a changed target keeps its own (reset) state
            try await session.raw("""
                UPDATE sdk_targets SET installed_version = \(bind: newInstalled), previous_version = \(bind: newPrev), last_result = \(bind: lastResult),
                  last_attempt_version = \(bind: action == .install ? to : (ok ? t.installed_version : nil)), run_phase = NULL, run_action = NULL, run_trigger = NULL,
                  run_started_at = NULL, updated_at = \(bind: DB.time(finished))
                WHERE customer_id = \(bind: DB.bin(customer)) AND form_id = \(bind: DB.bin(form)) AND target_revision = \(bind: rev)
                """).run()
            try await session.raw("COMMIT").run()
        } catch { try? await session.raw("ROLLBACK").run(); throw error }
        logger.info("sdk deployment", metadata: ["form": "\(form.uuidString.lowercased())", "action": "\(action.rawValue)", "trigger": "\(trigger.rawValue)", "result": "\(ok ? "ok" : errorCode ?? "failed")"])
        return Result(ok: ok, from: t.installed_version, to: ok ? newInstalled : to, errorCode: errorCode)
    }

    /// Targets with `auto_update` that are installed, older than the shipped SDK and not yet attempted for this version. Never installs
    /// a first time, never downgrades, never retries the same version after a failure.
    public func runAutomaticUpdates() async throws -> Int {
        try await (db as! SQLDatabase).withSession { try await self.runAutomaticUpdates(on: $0) }
    }

    fileprivate func runAutomaticUpdates(on session: SQLDatabase) async throws -> Int {
        // open runs first, independent of auto_update and versions (codex gegenlesen 3): a crashed run is closed by the next round,
        // not only when another run of that form happens to start. A held form lock means the run is alive.
        struct Open: Decodable { let customer_id: Blob; let form_id: Blob }
        for o in try await session.raw("SELECT customer_id, form_id FROM sdk_targets WHERE run_phase IS NOT NULL").all(decoding: Open.self) {
            guard let c = DB.uuid(o.customer_id.data), let f = DB.uuid(o.form_id.data) else { continue }
            let lock = Self.formLockName(f)
            struct L: Decodable { let l: Int? }
            guard try await session.raw("SELECT GET_LOCK(\(literal: lock), 0) AS l").first(decoding: L.self)?.l == 1 else { continue }
            do { try await Self.closeOpenRun(session, customer: c, form: f, now: now(), logger: logger) } catch { logger.error("closing an open sdk run failed") }
            _ = try? await session.raw("SELECT RELEASE_LOCK(\(literal: lock))").run()
        }
        guard let b = try? bundle() else { return 0 }
        struct R: Decodable { let customer_id: Blob; let form_id: Blob; let installed_version: String?; let last_attempt_version: String?; let last_result: String? }
        let due = try await session.raw("""
            SELECT customer_id, form_id, installed_version, last_attempt_version, last_result FROM sdk_targets
            WHERE auto_update = 1 AND installed_version IS NOT NULL AND (last_result IS NULL OR last_result <> 'repair_required')
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

private final class PhaseBox: @unchecked Sendable {
    private let l = NSLock(); private var v: String?
    func set(_ p: String) { l.lock(); v = p; l.unlock() }
    var value: String? { l.lock(); defer { l.unlock() }; return v }
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
