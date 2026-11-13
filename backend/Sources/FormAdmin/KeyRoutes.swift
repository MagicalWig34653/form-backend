// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Fluent
import FormAuth
import FormCore
import FormCrypto
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Provisioning the pieces the ingest needs (VORGESCHLAGEN, contracts/ingest + crypto/schluessel.md):
/// - `PUT/GET /tenants/{t}/customer-key`: the customer's public X25519 data key (first generation; the private key never reaches the server).
/// - `POST /tenants/{t}/forms/{f}/sdk-credentials`: server-side Ed25519 request key + digest secret; the private signing seed is returned ONCE.
enum KeyRoutes {
    static let graceAfterRotation: TimeInterval = 3600   // the previous signing key stays valid for 1 h so SDK hosts can switch over

    struct SDKConfig: Encodable {
        let formId: String, tenantId: String, submitPath: String
        let customerKeyId: String, customerPublicKey: String
        let signingSeed: String, signingPublicKey: String, signingGeneration: Int
        let endpoints: [String]?
        let endpointSignature: String?
        let note: String
    }

    static func register(_ tenants: RoutesBuilder, guardian: AuthGuard, db: Database, perms: PermissionService, secrets: SecretStore,
                         now: @escaping @Sendable () -> Date) {
        let sql = db as! SQLDatabase

        tenants.get("customer-key") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            let row = try await active(sql, tenant)
            let known = try await customerExists(sql, tenant)
            try await perms.authorize(account: s.accountID!, "form.read", on: .customer(tenant), exists: known)
            guard let row else { throw Abort(.notFound) }
            return try FormAdmin.json(.ok, KeyBody(keyId: row.kid, publicKey: row.public_key.data.base64URLString, generation: Int(row.generation_no)))
        }

        tenants.put("customer-key") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId")
            struct Access: Decodable { let enc: String; let sealed: String }
            struct Recovery: Decodable { let salt: String; let iterations: Int; let iv: String; let wrap: String }
            struct B: Decodable { let publicKey: String; let access: Access?; let recovery: Recovery? }
            let b: B = try FormAdmin.decodeStrict(req, allowed: ["publicKey", "access", "recovery"])
            // Browser-generated key: the data key is granted to the executing account and a recovery wrap is stored, both or neither.
            guard (b.access == nil) == (b.recovery == nil) else { throw ValidationFailed(detail: "access und recovery nur gemeinsam") }
            var accessRow: (enc: Data, sealed: Data)?, recoveryRow: (salt: Data, iv: Data, wrap: Data)?
            if let a = b.access, let r = b.recovery {
                guard let enc = Data(base64URLString: a.enc), enc.count == 32, let sealed = Data(base64URLString: a.sealed), sealed.count == 48,
                      let salt = Data(base64URLString: r.salt), salt.count == 32, r.iterations == 600_000,
                      let iv = Data(base64URLString: r.iv), iv.count == 12, let wrap = Data(base64URLString: r.wrap), wrap.count == 48
                else { throw ValidationFailed(detail: "access (enc 32, sealed 48), recovery (salt 32, iterations 600000, iv 12, wrap 48), base64url") }
                accessRow = (enc, sealed); recoveryRow = (salt, iv, wrap)
            }
            guard let pk = Data(base64URLString: b.publicKey), pk.count == 32, (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk)) != nil,
                  pk.contains(where: { $0 != 0 }), usableForKeyAgreement(pk) else { throw ValidationFailed(detail: "publicKey: 32 Byte X25519, base64url (kein Punkt kleiner Ordnung)") }
            let account = s.accountID!
            try await perms.authorize(account: account, "key.manage", on: .customer(tenant), exists: try await customerExists(sql, tenant))
            try await guardian.requireFreshAuthentication(s, now: now())
            let kid = try keyID(pk)
            let t = DB.time(now())
            var generationNo = 1
            do {
                generationNo = try await db.transaction { conn in
                    let tx = conn as! SQLDatabase
                    guard try await customerExists(tx, tenant, lock: true) else { throw Abort(.notFound) }
                    try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .customer(tenant))   // again under the lock (review M5)
                    if try await active(tx, tenant) != nil { throw Abort(.conflict) }     // rotation is not part of this scope
                    struct N: Decodable { let n: Int }
                    let next = (try await tx.raw("SELECT COALESCE(MAX(generation_no),0) AS n FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant))").first(decoding: N.self)?.n ?? 0) + 1
                    try await tx.raw("""
                        INSERT INTO customer_key_generations (generation_id, customer_id, kid, generation_no, public_key, state, created_by, created_at)
                        VALUES (\(bind: DB.bin(UUID())), \(bind: DB.bin(tenant)), \(bind: kid), \(bind: next), \(bind: Blob(pk)), 'active', \(bind: DB.bin(account)), \(bind: t))
                        """).run()
                    if let a = accessRow, let r = recoveryRow {
                        guard try await tx.raw("SELECT COUNT(*) AS c FROM account_keys WHERE account_id = \(bind: DB.bin(account))").first(decoding: FormAdmin.CountRow.self)?.c == 1
                        else { throw ValidationFailed(detail: "Zuerst den Kontoschlüssel einrichten") }
                        try await tx.raw("""
                            INSERT INTO data_key_access (customer_id, kid, account_id, enc, sealed_key, granted_by, granted_at)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: kid), \(bind: DB.bin(account)), \(bind: Blob(a.enc)), \(bind: Blob(a.sealed)), \(bind: DB.bin(account)), \(bind: t))
                            """).run()
                        try await tx.raw("""
                            INSERT INTO data_key_recovery (customer_id, kid, kdf_name, salt, iterations, iv, wrapped_key, created_at)
                            VALUES (\(bind: DB.bin(tenant)), \(bind: kid), 'pbkdf2-hmac-sha256', \(bind: Blob(r.salt)), 600000, \(bind: Blob(r.iv)), \(bind: Blob(r.wrap)), \(bind: t))
                            """).run()
                    }
                    try await ReleaseRoutes.audit(tx, tenant: tenant, form: nil, actor: account, action: "key.customer.register", subject: tenant, at: t, category: "key").run()
                    return next
                }
            } catch { if DB.isDuplicateKey(error) { throw Abort(.conflict) }; throw error }
            return try FormAdmin.json(.created, KeyBody(keyId: kid, publicKey: pk.base64URLString, generation: generationNo))
        }

        tenants.post("forms", ":formId", "sdk-credentials") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req)
            let tenant = try FormAdmin.uuidParam(req, "tenantId"), formID = try FormAdmin.uuidParam(req, "formId")
            let account = s.accountID!
            let exists = try await sql.raw("SELECT COUNT(*) AS c FROM forms WHERE id = \(bind: DB.bin(formID)) AND customer_id = \(bind: DB.bin(tenant))").first(decoding: FormAdmin.CountRow.self)?.c == 1
            try await perms.authorize(account: account, "key.manage", on: .form(customer: tenant, form: formID), exists: exists)
            try await guardian.requireFreshAuthentication(s, now: now())
            struct EndpointInput: Decodable { let endpoints: [String]? }
            let input: EndpointInput = (req.body.data?.readableBytes ?? 0) > 0
                ? try FormAdmin.decodeStrict(req, allowed: ["endpoints"]) : EndpointInput(endpoints: nil)
            if let endpoints = input.endpoints { try validateEndpoints(endpoints) }
            let seed = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let pub = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
            let t0 = now(), ts = DB.time(t0)
            let (generation, customerKey): (Int, KeyRow) = try await db.transaction { conn in
                let tx = conn as! SQLDatabase
                // lock the form first (no earlier snapshot read in this transaction: MariaDB error 1020)
                guard try await tx.raw("SELECT id FROM forms WHERE id = \(bind: DB.bin(formID)) AND customer_id = \(bind: DB.bin(tenant)) FOR UPDATE").first(decoding: FormAdmin.CountRowID.self) != nil else { throw Abort(.notFound) }
                try await PermissionService(sql: tx).authorize(account: account, "key.manage", on: .form(customer: tenant, form: formID))
                guard let ck = try await active(tx, tenant) else { throw ValidationFailed(detail: "Für den Kunden ist noch kein Datenschlüssel hinterlegt (PUT /customer-key).") }
                if let endpoints = input.endpoints {
                    // Existing host management owns activation and per-form/release authorization.
                    struct Host: Decodable { let host_ascii: String; let release_id: Blob? }
                    let hosts = try await tx.raw("""
                        SELECT h.host_ascii, f.release_id FROM api_hosts h JOIN api_host_forms f ON f.api_host_id = h.id
                        WHERE f.customer_id = \(bind: DB.bin(tenant)) AND f.form_id = \(bind: DB.bin(formID)) AND h.enabled = 1 FOR UPDATE
                        """).all(decoding: Host.self)
                    var releases: [Data?] = []
                    for endpoint in endpoints {
                        let hostname = String(endpoint.dropFirst(8))
                        guard let host = hosts.first(where: { $0.host_ascii == hostname }) else {
                            throw ValidationFailed(detail: "Jeder SDK-Endpunkt muss als aktiver API-Host für dieses Formular zugelassen sein.")
                        }
                        releases.append(host.release_id?.data)
                    }
                    guard releases.allSatisfy({ $0 == releases.first! }) else {
                        throw ValidationFailed(detail: "Failover-Hosts müssen dieselbe Releasebindung verwenden.")
                    }
                }
                struct N: Decodable { let n: Int }
                let next = (try await tx.raw("SELECT COALESCE(MAX(generation_no),0) AS n FROM form_protocol_keys WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID)) AND purpose = 'ed25519'").first(decoding: N.self)?.n ?? 0) + 1
                // older "previous" generations are revoked, the current one gets a grace period
                try await tx.raw("UPDATE form_protocol_keys SET state = 'revoked', valid_until = NULL WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID)) AND purpose = 'ed25519' AND state = 'previous'").run()
                try await tx.raw("UPDATE form_protocol_keys SET state = 'previous', valid_until = \(bind: DB.time(t0.addingTimeInterval(graceAfterRotation))) WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID)) AND purpose = 'ed25519' AND state = 'current'").run()
                try await tx.raw("""
                    INSERT INTO form_protocol_keys (customer_id, form_id, purpose, generation_no, public_key, secret_ref, state, valid_until, created_at)
                    VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), 'ed25519', \(bind: next), \(bind: Blob(pub)), NULL, 'current', NULL, \(bind: ts))
                    """).run()
                // the digest key is created once and kept (changing it would orphan stored request digests of earlier replays)
                struct D: Decodable { let generation_no: Int }
                if try await tx.raw("SELECT generation_no FROM form_protocol_keys WHERE customer_id = \(bind: DB.bin(tenant)) AND form_id = \(bind: DB.bin(formID)) AND purpose = 'digest-hmac' AND state = 'current'").first(decoding: D.self) == nil {
                    let ref = try await secrets.put(Data((0..<32).map { _ in UInt8.random(in: 0...255) }), on: tx)
                    try await tx.raw("""
                        INSERT INTO form_protocol_keys (customer_id, form_id, purpose, generation_no, public_key, secret_ref, state, valid_until, created_at)
                        VALUES (\(bind: DB.bin(tenant)), \(bind: DB.bin(formID)), 'digest-hmac', 1, NULL, \(bind: ref), 'current', NULL, \(bind: ts))
                        """).run()
                }
                try await ReleaseRoutes.audit(tx, tenant: tenant, form: formID, actor: account, action: "key.sdk.issue", subject: formID, at: ts, category: "key").run()
                return (next, ck)
            }
            let cfg = SDKConfig(formId: formID.uuidString.lowercased(), tenantId: tenant.uuidString.lowercased(), submitPath: "/api/v2/submit/",
                                customerKeyId: customerKey.kid, customerPublicKey: customerKey.public_key.data.base64URLString,
                                signingSeed: seed.base64URLString, signingPublicKey: pub.base64URLString, signingGeneration: generation,
                                endpoints: input.endpoints,
                                endpointSignature: try input.endpoints.map { endpoints in
                                    let text = "KUBUS-SDK-CONFIG-V1\n" + formID.uuidString.lowercased() + "\n" + endpoints.joined(separator: "\n")
                                    return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: Data(text.utf8)).base64URLString
                                },
                                note: "Der Signaturschlüssel (signingSeed) wird nur jetzt angezeigt und nicht gespeichert. Auf dem Kundensystem geheim ablegen.")
            let res = try FormAdmin.json(.created, cfg)
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
    }

    /// Signed configuration uses canonical HTTPS origins, never forwarded request headers.
    static func validateEndpoints(_ endpoints: [String]) throws {
        guard (1...10).contains(endpoints.count), Set(endpoints).count == endpoints.count,
              endpoints.allSatisfy({ endpoint in
                  guard endpoint.hasPrefix("https://") else { return false }
                  let host = String(endpoint.dropFirst(8))
                  return host.count <= 253 && host.contains(".") && host == host.lowercased()
                      && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                          !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
                              && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
                      }
              }) else { throw ValidationFailed(detail: "endpoints: 1–10 eindeutige HTTPS-Ursprünge mit kleingeschriebenem DNS-Namen, ohne Port/Pfad") }
    }

    /// A low-order point yields an all-zero shared secret (HPKE refuses it), which would make every submission of the customer fail.
    static func usableForKeyAgreement(_ pk: Data) -> Bool {
        guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk) else { return false }
        guard let secret = try? Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(with: pub) else { return false }
        return secret.withUnsafeBytes { $0.contains(where: { $0 != 0 }) }
    }

    struct KeyBody: Encodable { let keyId: String; let publicKey: String; let generation: Int }
    struct KeyRow: Decodable { let kid: String; let public_key: Blob; let generation_no: UInt64 }

    static func active(_ sql: SQLDatabase, _ tenant: UUID) async throws -> KeyRow? {
        try await sql.raw("SELECT kid, public_key, generation_no FROM customer_key_generations WHERE customer_id = \(bind: DB.bin(tenant)) AND state = 'active'").first(decoding: KeyRow.self)
    }

    static func customerExists(_ sql: SQLDatabase, _ tenant: UUID, lock: Bool = false) async throws -> Bool {
        try await sql.raw("SELECT COUNT(*) AS c FROM customers WHERE id = \(bind: DB.bin(tenant)) AND state = 'active' \(unsafeRaw: lock ? "FOR UPDATE" : "")").first(decoding: FormAdmin.CountRow.self)?.c == 1
    }
}
