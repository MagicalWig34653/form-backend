// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormPersistence
import SQLKit
import Foundation
import Vapor

/// Auth part of the admin API (contracts/auth/admin-api.openapi.yaml, base path /admin/api/v1):
/// getSession, passkeyOptions, passkeyVerify, verifySecondFactorPassword, logout.
public enum FormAuth {
    public static let maxBodyBytes = 16 * 1024

    /// Registers the routes. Wiring into `main.swift` is the coordinator's task (needs the server key provider, D9).
    @discardableResult
    public static func register(_ app: Application, config: AuthConfig, keys: any ServerKeyProvider,
                                passwords: any PasswordVerifier = DefaultPasswordVerifier(), now: @escaping @Sendable () -> Date = { Date() }) -> AuthGuard {
        let db = app.db(.mysql)
        let sessions = SessionService(db: db, keys: keys, audience: config.listener, now: now)
        let throttles = ThrottleService(db: db, keys: keys, now: now)
        let guardian = AuthGuard(sessions: sessions, throttles: throttles, config: config)
        let login = LoginService(db: db, sessions: sessions, throttles: throttles, passwords: passwords, relyingParty: config.relyingParty, secondFactorRequired: config.secondFactorRequired, now: now)
        let auth = app.grouped("admin", "api", "v1", "auth")

        auth.get("session") { req async throws -> Response in
            try await guardian.budget(req)
            if let s = try await guardian.currentSession(req) { return try await sessionResponse(s, sessions: sessions, guardian: guardian, token: nil) }
            let (token, s) = try await sessions.createAnonymous()
            return try await sessionResponse(s, sessions: sessions, guardian: guardian, token: token)
        }

        auth.post("passkey", "options") { req async throws -> Response in
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            let issued = try await login.beginPasskey(session: s)
            let body = PasskeyOptionsBody(
                challengeId: issued.id.uuidString.lowercased(),
                publicKey: .init(challenge: issued.challenge.base64URL, rpId: config.relyingParty.rpID, timeout: Int(LoginService.challengeLifetime * 1000),
                                 userVerification: "required", allowCredentials: []),
                expiresAt: iso(issued.expiresAt))
            return try json(body)
        }

        auth.post("passkey", "verify") { req async throws -> Response in
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            let wire: PasskeyVerifyBody = try decodeBody(req)
            let (credential, challengeID) = try wire.parsed()
            let (token, next) = try await login.finishPasskey(session: s, challengeID: challengeID, input: credential, clientIP: config.clientIP(req))
            return try await sessionResponse(next, sessions: sessions, guardian: guardian, token: token)
        }

        auth.post("second-factor", "password") { req async throws -> Response in
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            let body: SecondFactorBody = try decodeBody(req)
            guard body.method == "password", !body.password.isEmpty else { throw Abort(.badRequest) }
            let (token, next) = try await login.verifySecondFactorPassword(session: s, password: body.password, clientIP: config.clientIP(req))
            return try await sessionResponse(next, sessions: sessions, guardian: guardian, token: token)
        }

        let totp = TOTPService(db: db, secrets: SecretStore(db: db, keys: keys, now: now), now: now)
        // The listener is fixed server configuration; headers cannot enable this path internally.
        auth.post("totp") { req async throws -> Response in
            guard config.listener == "public" else { throw Abort(.notFound) }
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            struct Body: Decodable { let username: String?; let password: String?; let code: String }
            let b: Body = try decodeBody(req)
            let account: UUID, version: UInt64, method: String
            var verifiedHash: String?
            if s.state == .factorPending, let id = s.accountID {
                struct A: Decodable { let rights_version: UInt64 }
                guard let a = try await (db as! SQLDatabase).raw("SELECT rights_version FROM accounts WHERE id = \(bind: DB.bin(id)) AND active = 1").first(decoding: A.self) else { throw Abort(.unauthorized) }
                account = id; version = a.rights_version; method = "passkey+totp"
            } else {
                guard s.state == .anonymous, let rawUsername = b.username, let password = b.password, rawUsername.utf8.count <= 255, password.utf8.count <= 1024 else { throw Abort(.badRequest) }
                let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                // Lower-cased: the account lookup is case-insensitive (MariaDB collation), so spelling variants must share one lockout counter.
                let key = "totp-password|" + username.lowercased()
                try await throttles.ensureNotLocked(.account, key)
                struct A: Decodable { let id: Blob; let password_hash: String; let active: Int; let rights_version: UInt64 }
                let a = try await (db as! SQLDatabase).raw("SELECT id, password_hash, active, rights_version FROM accounts WHERE username = \(bind: username)").first(decoding: A.self)
                let ok = await passwords.verify(password: password, hash: a?.active == 1 && a?.password_hash.isEmpty == false ? a?.password_hash : nil)
                guard ok, let a, let id = DB.uuid(a.id.data) else {
                    try await throttles.recordFailure(.account, key, policy: .passwordPerAccount)
                    throw AuthenticationFailed.translate(SecondFactorError.passwordMismatch)
                }
                account = id; version = a.rights_version; method = "password+totp"; verifiedHash = a.password_hash
            }
            try await totp.verify(account: account, code: b.code)
            if let verifiedHash {
                // A password change that committed while this login was in flight must not yield a session (ADR 0027): the hash we
                // verified has to still be the current one and the account still active.
                struct Current: Decodable { let password_hash: String; let active: Int }
                let now = try await (db as! SQLDatabase).raw("SELECT password_hash, active FROM accounts WHERE id = \(bind: DB.bin(account))").first(decoding: Current.self)
                guard let now, now.active == 1, now.password_hash == verifiedHash else {
                    throw AuthenticationFailed.translate(SecondFactorError.passwordMismatch)
                }
            }
            let (token, next) = try await sessions.rotate(from: s, to: .authenticated, accountID: account, method: method, rightsVersion: version)
            return try await sessionResponse(next, sessions: sessions, guardian: guardian, token: token)
        }
        let me = app.grouped("admin", "api", "v1", "me", "totp")
        me.get { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: false)
            try await guardian.budget(req)
            return try json(["enabled": try await totp.enabled(account: s.accountID!)])
        }
        me.post { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req, login: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            let res = try json(["secret": try await totp.begin(account: s.accountID!)])
            res.headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return res
        }
        me.put { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req, login: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            struct B: Decodable { let code: String }
            let b: B = try decodeBody(req)
            try await totp.verify(account: s.accountID!, code: b.code, confirming: true)
            return Response(status: .noContent)
        }
        me.delete { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req, login: true)
            try await guardian.requireFreshAuthentication(s, now: now())
            struct B: Decodable { let password: String }
            let b: B = try decodeBody(req)
            let key = "totp-remove|" + s.accountID!.uuidString
            try await throttles.ensureNotLocked(.account, key)
            do { try await totp.remove(account: s.accountID!, password: b.password) }
            catch let error as Abort where error.status == .unauthorized {
                try await throttles.recordFailure(.account, key, policy: .passwordPerAccount); throw error
            }
            return Response(status: .noContent)
        }

        // --- Passkey registration -------------------------------------------------------------------------------------
        let registration = RegistrationService(db: db, relyingParty: config.relyingParty, now: now)
        let enrollmentsSvc = registration.enrollments
        let fresh: TimeInterval = 300

        /// Door 1: one-time enrollment token (anonymous session). Every refusal is the same `registration_failed`.
        auth.post("enrollment", "options") { req async throws -> Response in
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            let b: EnrollmentOptionsBody = try decodeBody(req)
            let ip = config.clientIP(req)
            try await throttles.ensureNotLocked(.ip, ip)
            do {
                guard s.state == .anonymous, let e = try await enrollmentsSvc.lookup(b.token) else { throw RegistrationError.enrollmentInvalid }
                return try creationOptionsResponse(try await registration.begin(session: s, account: e.account), rp: config.relyingParty)
            } catch let e as RegistrationError {
                try? await throttles.recordFailure(.ip, ip, policy: .passwordPerIP)
                throw RegistrationFailed.translate(e)
            }
        }

        auth.post("enrollment", "verify") { req async throws -> Response in
            try await guardian.budget(req, login: true)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            let b: RegistrationVerifyBody = try decodeBody(req)
            let parsed = try b.parsed()
            let ip = config.clientIP(req)
            try await throttles.ensureNotLocked(.ip, ip)
            do {
                guard s.state == .anonymous, let token = b.token, let e = try await enrollmentsSvc.lookup(token) else { throw RegistrationError.enrollmentInvalid }
                try await registration.finish(session: s, account: e.account, challengeID: parsed.challengeID, clientDataJSON: parsed.clientData,
                                              attestationObject: parsed.attestation, label: b.label, enrollmentID: e.id)
            } catch let e as RegistrationError {
                try? await throttles.recordFailure(.ip, ip, policy: .passwordPerIP)
                throw RegistrationFailed.translate(e)
            }
            return try json(RegisteredBody(status: "registered"))
        }

        /// Door 2: an authenticated session with a fresh authentication adds a passkey to its own account.
        auth.post("passkeys", "options") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req, login: true)
            guard let at = try await sessions.authenticatedAt(s), now().timeIntervalSince(at) <= fresh else { throw ReauthenticationRequired() }
            do { return try creationOptionsResponse(try await registration.begin(session: s, account: s.accountID!), rp: config.relyingParty) }
            catch let e as RegistrationError { throw RegistrationFailed.translate(e) }
        }

        auth.post("passkeys", "verify") { req async throws -> Response in
            let s = try await guardian.requireAuthenticated(req, mutation: true)
            try await guardian.budget(req, login: true)
            guard let at = try await sessions.authenticatedAt(s), now().timeIntervalSince(at) <= fresh else { throw ReauthenticationRequired() }
            let b: RegistrationVerifyBody = try decodeBody(req)
            let parsed = try b.parsed()
            do {
                try await registration.finish(session: s, account: s.accountID!, challengeID: parsed.challengeID, clientDataJSON: parsed.clientData,
                                              attestationObject: parsed.attestation, label: b.label)
            } catch let e as RegistrationError { throw RegistrationFailed.translate(e) }
            return try json(RegisteredBody(status: "registered"))
        }

        auth.post("logout") { req async throws -> Response in
            try await guardian.budget(req)
            let s = try await requireSession(req, guardian)
            try await guardian.requireCSRF(req, session: s)
            try await sessions.revoke(s)
            let res = Response(status: .noContent)
            res.headers.replaceOrAdd(name: .setCookie, value: AuthGuard.clearCookieHeader)
            return res
        }
        return guardian
    }

    // MARK: helpers

    private static func requireSession(_ req: Request, _ g: AuthGuard) async throws -> SessionRecord {
        guard let s = try await g.currentSession(req) else { throw Abort(.unauthorized) }
        return s
    }

    private static func creationOptionsResponse(_ o: RegistrationService.Options, rp: RelyingParty) throws -> Response {
        try json(CreationOptionsBody(
            challengeId: o.challengeID.uuidString.lowercased(),
            publicKey: .init(challenge: o.challenge.base64URL, rp: .init(id: rp.rpID, name: "Formular-Backend"),
                             user: .init(id: o.userHandle.base64URL, name: o.userName, displayName: o.userName),
                             pubKeyCredParams: [-7, -8, -257].map { .init(type: "public-key", alg: $0) }, timeout: Int(LoginService.challengeLifetime * 1000),
                             attestation: "none", authenticatorSelection: .init(residentKey: "required", requireResidentKey: true, userVerification: "required"),
                             excludeCredentials: o.excludeIDs.map { .init(type: "public-key", id: $0.base64URL) }),
            expiresAt: iso(o.expiresAt)))
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: d)
    }

    private static func json<T: Encodable>(_ v: T) throws -> Response {
        let res = Response(status: .ok)
        res.body = .init(data: try JSONEncoder().encode(v))
        res.headers.contentType = .json
        return res
    }

    private static func sessionResponse(_ s: SessionRecord, sessions: SessionService, guardian: AuthGuard, token: String?) async throws -> Response {
        guard let csrf = try await sessions.csrfToken(for: s) else { throw ServiceUnavailable() }
        let res = try json(SessionStateBody(state: s.state.rawValue, csrfToken: csrf, subjectId: s.state == .anonymous ? nil : s.accountID?.uuidString.lowercased(), expiresAt: iso(s.expiresAt), secondFactorRequired: guardian.config.secondFactorRequired, totpAllowed: guardian.config.listener == "public"))
        if let token { guardian.setCookie(res, token: token) }
        return res
    }

    private static func decodeBody<T: Decodable>(_ req: Request) throws -> T {
        guard req.headers.contentType == .json else { throw Abort(.unsupportedMediaType) }
        guard var buf = req.body.data, buf.readableBytes <= maxBodyBytes else {
            throw req.body.data == nil ? Abort(.badRequest) : Abort(.payloadTooLarge)
        }
        guard let data = buf.readData(length: buf.readableBytes), let v = try? JSONDecoder().decode(T.self, from: data) else { throw Abort(.badRequest) }
        return v
    }
}

// MARK: wire types

struct SessionStateBody: Encodable { let state: String; let csrfToken: String; let subjectId: String?; let expiresAt: String; let secondFactorRequired: Bool; let totpAllowed: Bool }

struct PasskeyOptionsBody: Encodable {
    struct PublicKey: Encodable { let challenge: String; let rpId: String; let timeout: Int; let userVerification: String; let allowCredentials: [String] }
    let challengeId: String; let publicKey: PublicKey; let expiresAt: String
}

struct SecondFactorBody: Decodable { let method: String; let password: String }

struct PasskeyVerifyBody: Decodable {
    struct Credential: Decodable {
        struct Response: Decodable { let authenticatorData: String; let clientDataJSON: String; let signature: String; let userHandle: String? }
        let id: String; let rawId: String; let type: String; let response: Response
    }
    let challengeId: String; let credential: Credential

    /// Strict structure check; format errors are plain 400 (independent of any secret state).
    func parsed() throws -> (AssertionInput, UUID) {
        guard let cid = UUID(uuidString: challengeId), credential.type == "public-key", credential.id == credential.rawId,
              let raw = Data(base64URLEncoded: credential.rawId), raw.count <= 255,
              let ad = Data(base64URLEncoded: credential.response.authenticatorData),
              let cd = Data(base64URLEncoded: credential.response.clientDataJSON),
              let sig = Data(base64URLEncoded: credential.response.signature) else { throw Abort(.badRequest) }
        var handle: Data? = nil
        if let h = credential.response.userHandle, !h.isEmpty {
            guard let d = Data(base64URLEncoded: h) else { throw Abort(.badRequest) }
            handle = d
        }
        return (AssertionInput(credentialID: raw, clientDataJSON: cd, authenticatorData: ad, signature: sig, userHandle: handle), cid)
    }
}

struct EnrollmentOptionsBody: Decodable { let token: String }
struct RegisteredBody: Encodable { let status: String }

struct CreationOptionsBody: Encodable {
    struct RP: Encodable { let id: String; let name: String }
    struct User: Encodable { let id: String; let name: String; let displayName: String }
    struct Param: Encodable { let type: String; let alg: Int }
    struct Selection: Encodable { let residentKey: String; let requireResidentKey: Bool; let userVerification: String }
    struct Cred: Encodable { let type: String; let id: String }
    struct PublicKey: Encodable {
        let challenge: String; let rp: RP; let user: User; let pubKeyCredParams: [Param]; let timeout: Int
        let attestation: String; let authenticatorSelection: Selection; let excludeCredentials: [Cred]
    }
    let challengeId: String; let publicKey: PublicKey; let expiresAt: String
}

struct RegistrationVerifyBody: Decodable {
    struct Credential: Decodable {
        struct Response: Decodable { let attestationObject: String; let clientDataJSON: String }
        let id: String; let rawId: String; let type: String; let response: Response
    }
    let token: String?; let challengeId: String; let label: String; let credential: Credential

    func parsed() throws -> (challengeID: UUID, clientData: Data, attestation: Data) {
        guard let cid = UUID(uuidString: challengeId), credential.type == "public-key", credential.id == credential.rawId,
              let raw = Data(base64URLEncoded: credential.rawId), raw.count <= 255,
              let cd = Data(base64URLEncoded: credential.response.clientDataJSON), let att = Data(base64URLEncoded: credential.response.attestationObject) else { throw Abort(.badRequest) }
        return (cid, cd, att)
    }
}
