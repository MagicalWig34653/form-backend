// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCrypto
import FormStorage
import FormAuth
import FormMail
import FormFlow
import FormCore
import FormWebhooks
import FormPersistence
import Fluent
import FluentMySQLDriver
import Foundation
import SQLKit
import Vapor

/// Resolves `form_protocol_keys.secret_ref` (purpose digest-hmac) to the 32-byte server key. The provider
/// (contract D9) is still open; production wiring is therefore NOT done in App (see handoff P5-A).
public protocol DigestSecretProvider: Sendable {
    func secret(ref: String) async throws -> Data?
}

public struct IngestConfig: Sendable {
    public var captcha: any CaptchaVerifier = TurnstileVerifier()
    public var malware: (any MalwareHashScanner)? = nil
    public var abuseKey: Data? = nil
    public var clientIP: @Sendable (Request) -> String = { $0.remoteAddress?.ipAddress ?? "unknown" }
    /// Per-(form, client) request budget (FA-015). nil = no budget (tests, unconfigured deployments).
    public var throttle: ThrottleService? = nil
    public var secrets: DigestSecretProvider
    public var now: @Sendable () -> Date
    /// Hard HTTP body limit (contract ingest/README, VORGESCHLAGEN: 32 MiB).
    public var maxBodyBytes: Int
    /// Submissions in flight per replica, checked before the body is collected (review Astra 2 M5). 0 = no budget.
    /// 16 x 32 MiB bounds the buffered bodies of one replica to 512 MiB.
    public var maxConcurrent: Int = 16
    public var webhookLimits: WebhookLimits?
    /// Outgoing mail (ADR 0010). nil = the application sends no mail.
    public var mail: MailDispatcher?
    /// Resolves the external host only through the deployment's trusted proxy contract.
    public var externalHost: @Sendable (Request) throws -> String?
    public init(secrets: DigestSecretProvider, now: @escaping @Sendable () -> Date = { Date() }, maxBodyBytes: Int = 33_554_432, mail: MailDispatcher? = nil, webhookLimits: WebhookLimits? = nil, externalHost: @escaping @Sendable (Request) throws -> String? = { _ in nil }) {
        self.secrets = secrets; self.now = now; self.maxBodyBytes = maxBodyBytes; self.webhookLimits = webhookLimits; self.mail = mail; self.externalHost = externalHost
    }
}

/// v2 submit endpoint (P5-A). Registers `/api/v2/submit/` (+ `/index.php` alias). Errors are thrown as `Abort`
/// and rendered by the application's error middleware (FormHTTP `ProblemMiddleware`); nothing here builds an
/// error body or logs request data.
public enum IngestSetup {
    public static func register(_ app: Application, config: IngestConfig) {
        app.http.client.configuration.redirectConfiguration = .disallow
        let handler = SubmitHandler(config: config)
        app.lifecycle.use(PacketStartupCheck(ingestLimitBytes: config.maxBodyBytes))
        let gated = app.grouped(IngestGate(maxConcurrent: config.maxConcurrent))   // runs before `body: .collect`
        for path in [["api", "v2", "submit"], ["api", "v2", "submit", "index.php"]] {
            gated.on(.POST, path.map { PathComponent(stringLiteral: $0) }, body: .collect(maxSize: ByteCount(value: config.maxBodyBytes))) { req in
                try await handler.submit(req)
            }
            for method in [HTTPMethod.GET, .PUT, .PATCH, .DELETE] {
                app.on(method, path.map { PathComponent(stringLiteral: $0) }) { _ -> Response in throw Abort(.methodNotAllowed) }
            }
        }
    }
}

struct SubmitHandler: Sendable {
    let config: IngestConfig

    private struct FormRow: Decodable { let customer_id: Blob; let active: Int; let current_release_id: Blob?; let cstate: String }
    private struct KeyRow: Decodable { let public_key: Blob? }
    private struct CustomerKeyRow: Decodable { let kid: String; let public_key: Blob }
    private struct DigestKeyRow: Decodable { let generation_no: Int64; let secret_ref: String? }
    private struct IdemRow: Decodable {
        let submission_id: Blob; let request_digest: Blob?; let digest_key_generation: Int64?
        let digest_evidence: String; let state: String; let result_state: String
    }

    /// `ingest.requestsPerMinute` (0 = off). Counters live in `auth_throttles` as HMAC only; the IP is never stored in clear.
    func enforceBudget(_ req: Request, sql: SQLDatabase, form: UUID) async throws {
        guard let throttle = config.throttle else { return }
        let limit = Int(try await SystemSettings.value("ingest.requestsPerMinute", sql: sql))!
        guard limit > 0 else { return }
        let raw = config.clientIP(req)
        let ip = IPAddr(raw)?.text ?? raw
        do { try await throttle.consume(.adminRoute, "ingest|\(form.uuidString.lowercased())|\(ip)", limit: limit, window: 60) }
        catch let e as RateLimited { throw IngestRateLimited(retryAfterSeconds: e.retryAfter) }
    }

    func submit(_ req: Request) async throws -> Response {
        // 1. Form parameter (contract: missing/empty -> 401, unknown -> 404). Only lowercase canonical UUIDs can name a form.
        guard let f = try? req.query.get(String?.self, at: "f"), !f.isEmpty else { throw Abort(.unauthorized) }
        guard let formUUID = Self.canonicalUUID(f) else { throw Abort(.notFound) }
        let sql = req.db(.mysql) as! SQLDatabase
        let now = config.now()

        guard let form = try await sql.raw("""
            SELECT f.customer_id, f.active, f.current_release_id, c.state AS cstate
            FROM forms f JOIN customers c ON c.id = f.customer_id WHERE f.id = \(bind: Self.bin(formUUID))
            """).first(decoding: FormRow.self), form.active == 1, form.cstate == "active" else { throw Abort(.notFound) }

        // 1b. Budget per (form, client IP) before any parsing/hashing/sealing; replays with the same key count too (FA-015).
        try await enforceBudget(req, sql: sql, form: formUUID)

        // 2. Body: only urlencoded in P5-A (multipart/uploads are not part of this package).
        guard let ct = req.headers.contentType else { throw Abort(.unsupportedMediaType) }
        // Cheap pre-check before any parsing (review M6): without well-formed signature headers nothing is parsed or hashed.
        guard let tsHeader = req.headers.first(name: "X-Kubus-Timestamp"), !tsHeader.isEmpty, tsHeader.utf8.count <= 20,
              let sigHeader = req.headers.first(name: "X-Kubus-Signature"), sigHeader.utf8.count == 88,
              let sigRaw = Data(base64Encoded: sigHeader), sigRaw.count == 64,
              RequestSignature.validTimestamp(tsHeader, now: Int64(now.timeIntervalSince1970)) else { throw Abort(.forbidden) }   // stale requests are not parsed (M5)
        let body = req.body.data.map { Array($0.readableBytesView) } ?? []
        var uploads: [Upload] = []
        let fields: PHPValue
        var fileFields: [(String, FileField)] = []
        if ct.type == "application", ct.subType == "x-www-form-urlencoded" {
            fields = try FormEncodedParser.parse(body)
        } else if let boundary = MultipartParser.boundary(of: ct) {
            let m = try MultipartParser.parse(body, boundary: boundary)
            fields = try FormEncodedParser.parse(m.urlencoded)
            (uploads, fileFields) = try Uploads.prepare(m.files)
        } else { throw Abort(.unsupportedMediaType) }
        let canonical: Data
        do { canonical = try RequestSignature.canonical(fields: fields, files: fileFields) } catch { throw Abort(.preconditionFailed) }

        // 3. Signature (before any idempotency lookup so a hit never reveals an identity to an unauthenticated caller).
        try await verifySignature(req, sql: sql, form: form, formID: f, formUUID: formUUID, canonical: canonical, now: now)

        let statisticsContext = try IngestStatistics.context(canonical: canonical)
        struct HostCount: Decodable { let c: Int }
        let hostRequired = try await sql.raw("SELECT COUNT(*) AS c FROM api_host_forms WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID))").first(decoding: HostCount.self)?.c ?? 0
        let externalHost = hostRequired > 0 ? try config.externalHost(req) : nil
        let releaseID = try await IngestStatistics.resolveRelease(sql: sql, customer: form.customer_id, form: formUUID,
            current: form.current_release_id, host: externalHost)
        let ingestPolicy = try await AbuseProtection.policy(sql: sql, form: formUUID, customer: form.customer_id, release: releaseID)
        try await IngestStatistics.checkOrigin(statisticsContext, origins: req.headers["Origin"], sql: sql,
            customer: form.customer_id, form: formUUID, release: releaseID, environment: ingestPolicy.testMode ? "test" : "production")

        // A release whose policy promises the transport envelope is never served by the plain route (defence in depth, review H3).
        if let pol = try await sql.raw("""
            SELECT fv.transport_policy AS transport_policy FROM releases r
            JOIN form_versions fv ON fv.customer_id = r.customer_id AND fv.form_id = r.form_id AND fv.version_no = r.form_version_no
            WHERE r.id = \(bind: releaseID) AND r.customer_id = \(bind: form.customer_id)
            """).first(decoding: PolicyRow.self), pol.transport_policy == "required" { throw Abort(.serviceUnavailable) }

        // 4. Server-side prerequisites. No fallback for a missing release or recipient key.
        guard let recipient = try await sql.raw("""
            SELECT kid, public_key FROM customer_key_generations WHERE customer_id = \(bind: form.customer_id) AND state = 'active'
            """).first(decoding: CustomerKeyRow.self),
              recipient.public_key.data.count == 32, (try? keyID(recipient.public_key.data)) == recipient.kid
        else { throw Abort(.serviceUnavailable) }

        // 5. Idempotency key and fachdigest (HMAC of the signed body hash, contract D1).
        let idemKey = Self.effectiveIdempotencyKey(req.headers.first(name: "Idempotency-Key"))
        var digest: (generation: Int64, value: Data)?
        if idemKey != nil {
            digest = try await currentDigest(sql: sql, form: form, formID: f, formUUID: formUUID, canonical: canonical)
            // The fast path of a replay is evaluated before sealing: no new row, no new package.
            if let key = idemKey, let hit = try await existing(sql: sql, form: form, formUUID: formUUID, key: key) {
                if let storage = req.application.storage[StorageServiceKey.self], let sid = DB.uuid(hit.submission_id.data) { try await storage.flush(submission: sid) }
                return try await replay(hit, sql: sql, form: form, formID: f, formUUID: formUUID, current: digest!, canonical: canonical)
            }
        }

        let protection = try await AbuseProtection.check(req: req, config: config, form: formUUID, customer: form.customer_id,
            release: releaseID, canonical: canonical, uploads: uploads, now: now, policy: ingestPolicy)
        let environment = protection.test ? "test" : "production"

        // 5b. Field validation against the published form (parity FA-024); transport/captcha fields are not stored or forwarded (ADR 0034).
        let definition = try await definitionOf(sql: sql, customer: form.customer_id, form: formUUID, release: releaseID)
        if let definition { try SubmissionValidation.validate(canonical: canonical, definition: definition) }
        let stored = SubmissionValidation.discardUnknown(canonical: SubmissionValidation.stripTransport(canonical: canonical), definition: definition)

        // 6. Seal (server holds only the public key). Plaintext = the signed canonical JSON bytes without transport fields (signature and digest stay on the original).
        let package = try PackageV2.seal(stored, recipient: recipient.public_key.data)
        let wire = Data(package.wire.utf8)

        // Attachments are sealed to the same key, one object each (ordinal = position in the signed `files` order).
        var sealedUploads = uploads
        for i in sealedUploads.indices {
            let pkg = try PackageV2.seal(sealedUploads[i].content, recipient: recipient.public_key.data)
            sealedUploads[i].wire = Data(pkg.wire.utf8); sealedUploads[i].kid = pkg.kid
            sealedUploads[i].payloadHash = Data(SHA256.hash(data: pkg.iv + pkg.ciphertext + pkg.tag))
        }
        let uploadsForTx = sealedUploads
        let submissionID = UUID()
        let kid = package.kid
        // Immutable payload identity SHA-256(iv||ct||tag) (objektinventar R07), independent of the wrap segments.
        let payloadHash = Blob(Data(SHA256.hash(data: package.iv + package.ciphertext + package.tag)))
        let digestForTx = digest
        // Mail (ADR 0010): the plan comes from the published form version; the plaintext fields exist only in this request's memory.
        let flowDefinition = try await FlowEngine.definition(sql: sql, customer: form.customer_id, form: Self.bin(formUUID), release: releaseID)
        if flowDefinition != nil && digest == nil {
            digest = try await currentDigest(sql: sql, form: form, formID: f, formUUID: formUUID, canonical: canonical)
        }
        let flowDigest = digest
        let flowState = try flowDefinition.map { try FlowEngine.initialState($0, fields: JSONSerialization.data(withJSONObject: (try JSONSerialization.jsonObject(with: stored) as? [String: Any])?["fields"] as? [String: Any] ?? [:])) }
        var flowRun: UUID?
        let mailPlan: MailPlan? = flowDefinition != nil ? nil : config.mail == nil ? nil : try await mailPlanOf(sql: sql, customer: form.customer_id, form: formUUID, release: releaseID)
        let submittedFields = (try? JSONSerialization.jsonObject(with: stored) as? [String: Any])?["fields"] as? [String: Any] ?? [:]
        var prepared: [PreparedMail] = []
        // One retry (review P5-A B4): deadlock/lock-wait timeout, or a duplicate whose winner rolled back (no row to replay yet).
        for attempt in 0..<2 {
        flowRun = nil
        prepared = []   // rows of a failed attempt were rolled back with its transaction
        do {
            try await req.db(.mysql).transaction { tx in
                let t = tx as! SQLDatabase
                // Refuse BEFORE the first write when one sealed package cannot travel in one database packet (never "accepted" without data).
                try await PacketGuard.require(fit: max(wire.count, uploadsForTx.map(\.wire.count).max() ?? 0), on: t, logger: req.logger)
                // Serialize with key rotation. A request sealed before rotation must retry against the new public key.
                struct LockedCustomer: Decodable { let id: Blob }
                _ = try await t.raw("SELECT id FROM customers WHERE id = \(bind: form.customer_id) FOR UPDATE").first(decoding: LockedCustomer.self)
                guard try await t.raw("SELECT kid, public_key FROM customer_key_generations WHERE customer_id = \(bind: form.customer_id) AND state = 'active' FOR UPDATE").first(decoding: CustomerKeyRow.self)?.kid == kid else {
                    throw Abort(.conflict, reason: "Datenschlüssel wurde rotiert; Eingang wiederholen")
                }
                let ts = Self.dbTime(now)
                try await WebhookLimits.lockCustomer(t, customer: form.customer_id)
                // Idempotency row first: a concurrent duplicate blocks here until this transaction ends.
                if let key = idemKey, let d = digestForTx {
                    try await t.raw("""
                        INSERT INTO ingest_idempotency (customer_id, form_id, key_digest, submission_id, request_digest, digest_key_generation,
                          environment, release_id, release_evidence, result_state, digest_evidence, state, fence, created_at)
                        VALUES (\(bind: form.customer_id), \(bind: Self.bin(formUUID)), \(bind: Blob(Data(SHA256.hash(data: key)))), \(bind: Self.bin(submissionID)),
                          \(bind: Blob(d.value)), \(bind: d.generation), \(bind: environment), \(bind: releaseID), 'recorded', 'available', 'verified', 'complete', 0, \(bind: ts))
                        """).run()
                }
                // The idempotency insert MUST precede reads/host locks: concurrent identical requests
                // wait on this key before opening a read snapshot or acquiring any other locks.
                let lockedRelease = try await IngestStatistics.resolveRelease(sql: t, customer: form.customer_id, form: formUUID,
                    current: form.current_release_id, host: externalHost, lock: true)
                guard lockedRelease.data == releaseID.data else { throw Abort(.conflict) }
                try await t.raw("""
                    INSERT INTO submissions (id, customer_id, form_id, release_id, release_evidence, received_at, environment, state, removable, retention_due_at, malware_scan_status, captcha_status)
                    VALUES (\(bind: Self.bin(submissionID)), \(bind: form.customer_id), \(bind: Self.bin(formUUID)), \(bind: releaseID), 'recorded', \(bind: ts),
                      \(bind: environment), 'accepted', 1,
                      DATE_ADD(CAST(\(bind: ts) AS DATETIME(6)), INTERVAL COALESCE((SELECT CAST(JSON_VALUE(safe_value_json, '$') AS UNSIGNED) FROM settings
                        WHERE scope_key = \(bind: "form:" + formUUID.uuidString.lowercased()) AND setting_key = 'retention.days'), \(literal: Retention.defaultDays)) DAY),\(bind: protection.malware.rawValue), \(bind: protection.captcha.rawValue))
                    """).run()
                if let storage = req.application.storage[StorageServiceKey.self], let customer = DB.uuid(form.customer_id.data) {
                    try await storage.insert(sql: t, customer: customer, form: formUUID, submission: submissionID, role: "data", ordinal: 0, wire: wire, kid: kid, payloadHash: payloadHash.data, originalBytes: stored.count)
                    for (i, a) in uploadsForTx.enumerated() {
                        try await storage.insert(sql: t, customer: customer, form: formUUID, submission: submissionID, role: "attachment", ordinal: i, wire: a.wire, kid: a.kid, payloadHash: a.payloadHash, originalBytes: a.content.count)
                    }
                } else {
                try await t.raw("""
                    INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, ciphertext,
                      packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                    VALUES (\(bind: Self.bin(UUID())), \(bind: form.customer_id), \(bind: Self.bin(formUUID)), \(bind: Self.bin(submissionID)), 'data', 0, 0, 'db',
                      \(bind: Blob(wire)), 'KUBUS-AEAD:2', 'hpke', \(bind: kid), 'raw', \(bind: Blob(Data(SHA256.hash(data: wire)))), \(bind: payloadHash), \(bind: wire.count), 'ready')
                    """).run()
                for (i, a) in uploadsForTx.enumerated() {
                    try await t.raw("""
                        INSERT INTO stored_objects (id, customer_id, form_id, submission_id, object_role, ordinal_no, revision, backend, ciphertext,
                          packet_format, wrap_kind, kid, content_encoding, ciphertext_sha256, payload_sha256, byte_count, state)
                        VALUES (\(bind: Self.bin(UUID())), \(bind: form.customer_id), \(bind: Self.bin(formUUID)), \(bind: Self.bin(submissionID)), 'attachment', \(bind: i), 0, 'db',
                          \(bind: Blob(a.wire)), 'KUBUS-AEAD:2', 'hpke', \(bind: a.kid), 'raw', \(bind: Blob(Data(SHA256.hash(data: a.wire)))), \(bind: Blob(a.payloadHash)), \(bind: a.wire.count), 'ready')
                        """).run()
                }
                }
                if max(wire.count, uploadsForTx.map(\.wire.count).max() ?? 0) >= PacketGuard.checkThreshold {
                    try await PacketGuard.verifyStored(submission: Self.bin(submissionID), expected: 1 + uploadsForTx.count, on: t, logger: req.logger)
                }
                try await IngestStatistics.record(protection.test ? nil : statisticsContext, tx: t, customer: form.customer_id, form: formUUID, release: releaseID, submission: submissionID, now: now, origins: req.headers["Origin"])
                // A custom flow owns all delivery decisions (ADR 0017), including intentionally omitted hooks.
                // Only the standard placeholder uses automatic ingest delivery; replay never re-enters here.
                if flowDefinition == nil && !protection.test {
                    // Independent random delivery UUIDs, one per active endpoint.
                    let limits: WebhookLimits
                    if let configured = config.webhookLimits { limits = configured } else { limits = try await WebhookLimits.current(t) }
                    try await limits.enqueue(t, customer: form.customer_id, form: Self.bin(formUUID), submission: Self.bin(submissionID), at: ts)
                }
                if !protection.test, let definition = flowDefinition, let state = flowState, let d = flowDigest {
                    flowRun = try await FlowEngine(db: req.db(.mysql), mail: config.mail).prepare(tx: t, definition: definition, state: state, customer: form.customer_id, form: Self.bin(formUUID), release: releaseID, submission: submissionID, publicKey: recipient.public_key.data, digest: d.value, digestGeneration: d.generation, now: now)
                }
                // Delivery rows commit atomically with the submission; a replay (idempotent duplicate) never reaches this point.
                if let plan = mailPlan, let dispatcher = config.mail {
                    prepared = try await dispatcher.prepare(tx: t, plan: plan, customer: form.customer_id, form: Self.bin(formUUID), submission: submissionID, fields: submittedFields)
                }
            }
        } catch {
            // After rollback, read the winner on a fresh pooled connection, including after a
            // deadlock/timeout. Do not carry a losing transaction's snapshot into replay.
            if Self.isDuplicateKey(error) || Self.isRetryable(error), let key = idemKey, let d = digest,
               let hit = try await existing(sql: sql, form: form, formUUID: formUUID, key: key) {
                if let storage = req.application.storage[StorageServiceKey.self], let sid = DB.uuid(hit.submission_id.data) { try await storage.flush(submission: sid) }
                return try await replay(hit, sql: sql, form: form, formID: f, formUUID: formUUID, current: d, canonical: canonical)
            }
            if attempt == 0, Self.isRetryable(error) || (Self.isDuplicateKey(error) && idemKey != nil) { continue }
            // Persistent contention is a retryable request conflict, not an internal server error.
            if Self.isRetryable(error) { throw Abort(.conflict) }
            throw error
        }
                if let run = flowRun, let state = flowState {
                    // Run immediately with ephemeral plaintext; a process crash requires human recovery.
                    try? await FlowEngine(db: req.db(.mysql), mail: config.mail).execute(run: run, state: state)
                }
                config.mail?.dispatch(prepared)   // after the commit; never blocks or fails the response
                if let storage = req.application.storage[StorageServiceKey.self] { try await storage.flush(submission: submissionID) }
            return Self.accepted(submissionID, protection: protection)
        }
        throw Abort(.internalServerError)
    }

    private struct PolicyRow: Decodable { let transport_policy: String }
    private struct DefRow: Decodable { let definition_json: String }

    /// The `mail` section of the form version behind the release, nil when absent or invalid.
    private func definitionOf(sql: SQLDatabase, customer: Blob, form: UUID, release: Blob) async throws -> [String: Any]? {
        guard let r = try await sql.raw("""
            SELECT fv.definition_json AS definition_json FROM releases r
            JOIN form_versions fv ON fv.customer_id = r.customer_id AND fv.form_id = r.form_id AND fv.version_no = r.form_version_no
            WHERE r.id = \(bind: release) AND r.customer_id = \(bind: customer) AND r.form_id = \(bind: Self.bin(form))
            """).first(decoding: DefRow.self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(r.definition_json.utf8))) as? [String: Any]
    }

    private func mailPlanOf(sql: SQLDatabase, customer: Blob, form: UUID, release: Blob) async throws -> MailPlan? {
        guard let r = try await sql.raw("""
            SELECT fv.definition_json AS definition_json FROM releases r
            JOIN form_versions fv ON fv.customer_id = r.customer_id AND fv.form_id = r.form_id AND fv.version_no = r.form_version_no
            WHERE r.id = \(bind: release) AND r.customer_id = \(bind: customer) AND r.form_id = \(bind: Self.bin(form))
            """).first(decoding: DefRow.self),
              let def = (try? JSONSerialization.jsonObject(with: Data(r.definition_json.utf8))) as? [String: Any] else { return nil }
        return MailDispatcher.plan(definition: def)
    }

    // MARK: Signature

    private func verifySignature(_ req: Request, sql: SQLDatabase, form: FormRow, formID: String, formUUID: UUID, canonical: Data, now: Date) async throws {
        guard let ts = req.headers.first(name: "X-Kubus-Timestamp"), let sigB64 = req.headers.first(name: "X-Kubus-Signature"),
              let sig = Data(base64Encoded: sigB64), sig.base64EncodedString() == sigB64, sig.count == 64
        else { throw Abort(.forbidden) }
        let keys = try await sql.raw("""
            SELECT public_key FROM form_protocol_keys
            WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID)) AND purpose = 'ed25519'
              AND (state = 'current' OR (state = 'previous' AND valid_until >= \(bind: Self.dbTime(now))))
            """).all(decoding: KeyRow.self)
        // No exception path (signature_exceptions) in P5-A: no key or no valid signature -> 403, never an unsigned accept.
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let ok = keys.contains { k in
            k.public_key.map { RequestSignature.verify(signature: sig, route: .submit, formID: formID, timestamp: ts, canonical: canonical, publicKey: $0.data, now: nowSeconds) } ?? false
        }
        guard ok else { throw Abort(.forbidden) }
    }

    // MARK: Idempotency

    private func hmac(_ key: Data, formID: String, canonical: Data) -> Data {
        var msg = Data("KUBUS-DIGEST-1\n\(formID)\n".utf8)
        msg.append(Data(SHA256.hash(data: canonical)))
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }

    private func currentDigest(sql: SQLDatabase, form: FormRow, formID: String, formUUID: UUID, canonical: Data) async throws -> (generation: Int64, value: Data) {
        guard let row = try await sql.raw("""
            SELECT generation_no, secret_ref FROM form_protocol_keys
            WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID)) AND purpose = 'digest-hmac' AND state = 'current'
            """).first(decoding: DigestKeyRow.self),
              let ref = row.secret_ref, let key = try await config.secrets.secret(ref: ref), key.count == 32
        else { throw Abort(.serviceUnavailable) }
        return (row.generation_no, hmac(key, formID: formID, canonical: canonical))
    }

    private func existing(sql: SQLDatabase, form: FormRow, formUUID: UUID, key: Data) async throws -> IdemRow? {
        try await sql.raw("""
            SELECT submission_id, request_digest, digest_key_generation, digest_evidence, state, result_state FROM ingest_idempotency
            WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID)) AND key_digest = \(bind: Blob(Data(SHA256.hash(data: key))))
            """).first(decoding: IdemRow.self)
    }

    private func replay(_ hit: IdemRow, sql: SQLDatabase, form: FormRow, formID: String, formUUID: UUID, current: (generation: Int64, value: Data), canonical: Data) async throws -> Response {
        // Only a completed, available, digest-verified record can be replayed. Pending/review/deleted and legacy rows without a
        // digest -> 409 (deleted: ADR "Replay nach Loeschung -> 409"; legacy-missing: adoption of the legacy 200 is still VORGESCHLAGEN).
        guard hit.state == "complete", hit.result_state == "available", hit.digest_evidence == "verified",
              let stored = hit.request_digest?.data, let gen = hit.digest_key_generation else { throw Abort(.conflict) }
        var candidate = current.value
        if gen != current.generation {
            guard let row = try await sql.raw("""
                SELECT generation_no, secret_ref FROM form_protocol_keys
                WHERE customer_id = \(bind: form.customer_id) AND form_id = \(bind: Self.bin(formUUID)) AND purpose = 'digest-hmac' AND generation_no = \(bind: gen)
                """).first(decoding: DigestKeyRow.self),
                  let ref = row.secret_ref, let key = try await config.secrets.secret(ref: ref), key.count == 32
            else { throw Abort(.serviceUnavailable) }
            candidate = hmac(key, formID: formID, canonical: canonical)
        }
        guard candidate.count == stored.count, Self.constantTimeEqual(candidate, stored) else { throw Abort(.conflict) }
        guard let id = Self.uuid(hit.submission_id.data) else { throw Abort(.internalServerError) }
        struct Pending: Decodable { let c: Int }
        guard try await sql.raw("SELECT COUNT(*) AS c FROM stored_objects WHERE submission_id = \(bind: hit.submission_id) AND state <> 'ready'").first(decoding: Pending.self)?.c == 0 else { throw Abort(.conflict) }
        struct ProtectionRow: Decodable { let captcha_status: String; let malware_scan_status: String; let environment: String }
        let response = Self.accepted(id)
        if let status = try await sql.raw("SELECT captcha_status, malware_scan_status, environment FROM submissions WHERE id=\(bind: hit.submission_id) AND customer_id=\(bind: form.customer_id)").first(decoding: ProtectionRow.self) {
            response.headers.replaceOrAdd(name: "X-Form-Captcha", value: status.captcha_status)
            response.headers.replaceOrAdd(name: "X-Form-Malware", value: status.malware_scan_status)
            response.headers.replaceOrAdd(name: "X-Form-Mode", value: status.environment)
        }
        return response
    }

    // MARK: Helpers

    static func accepted(_ id: UUID, protection: AbuseProtection.Result? = nil) -> Response {
        let res = Response(status: .ok)
        res.headers.contentType = .json
        if let protection {
            res.headers.replaceOrAdd(name: "X-Form-Captcha", value: protection.captcha.rawValue)
            res.headers.replaceOrAdd(name: "X-Form-Malware", value: protection.malware.rawValue)
            res.headers.replaceOrAdd(name: "X-Form-Mode", value: protection.test ? "test" : "production")
        }
        res.body = .init(string: "{\"submission\":{\"id\":\"\(id.uuidString.lowercased())\"}}")
        return res
    }

    /// PHP trim set (SP, HT, LF, CR, NUL, VT); valid = 1...190 bytes after trim and no LF/NUL inside; otherwise absent.
    static func effectiveIdempotencyKey(_ raw: String?) -> Data? {
        guard let raw else { return nil }
        let trimSet: Set<UInt8> = [32, 9, 10, 13, 0, 11]
        var b = Array(raw.utf8)
        while let l = b.last, trimSet.contains(l) { b.removeLast() }
        while let f = b.first, trimSet.contains(f) { b.removeFirst() }
        guard (1...190).contains(b.count), !b.contains(10), !b.contains(0) else { return nil }
        return Data(b)
    }

    static func canonicalUUID(_ s: String) -> UUID? {
        guard s.utf8.count == 36, s == s.lowercased(), let u = UUID(uuidString: s) else { return nil }
        return u
    }
    static func bin(_ u: UUID) -> Blob { Blob(withUnsafeBytes(of: u.uuid) { Data($0) }) }
    static func uuid(_ d: Data) -> UUID? {
        guard d.count == 16 else { return nil }
        return d.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
    static func dbTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"
        return f.string(from: d)
    }
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
    /// 1213 deadlock, 1205 lock wait timeout: the statement/transaction may simply be repeated.
    static func isRetryable(_ error: Error) -> Bool {
        guard let e = error as? MySQLError, case .server(let p) = e else { return false }
        return p.errorCode.rawValue == 1213 || p.errorCode.rawValue == 1205
    }
    static func isDuplicateKey(_ error: Error) -> Bool {
        guard let e = error as? MySQLError else { return false }
        switch e {
        case .duplicateEntry: return true
        case .server(let p): return p.errorCode.rawValue == 1062
        default: return false
        }
    }
}

/// The client exceeded the per-form request budget; the SDK treats 429 as retryable and honours `Retry-After`.
public struct IngestRateLimited: PublicProblemError {
    public let retryAfter: Int
    public init(retryAfterSeconds: Int) { retryAfter = max(1, retryAfterSeconds) }
    public var statusCode: UInt { 429 }
    public var code: String { "ingest_rate_limited" }
    public var message: String { "Zu viele Anfragen für dieses Formular. Bitte später erneut versuchen." }
    public var extraHeaders: [(name: String, value: String)] { [("Retry-After", String(retryAfter))] }
}
