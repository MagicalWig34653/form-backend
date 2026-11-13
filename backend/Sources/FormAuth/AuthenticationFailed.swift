// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation

/// The ONE public category for every login verification failure (passkey, second factor), contracts/auth/
/// p5b-ergaenzung.md E4: status, code, text and headers are identical for all causes; only the request id
/// varies. The internal cause is kept in `auditReason` for the audit log and never reaches the response.
public struct AuthenticationFailed: PublicProblemError, Equatable {
    public static let code = "authentication_failed"
    public let auditReason: String?
    public var statusCode: UInt { 401 }
    public var code: String { Self.code }
    public var message: String { "Anmeldung fehlgeschlagen." }

    private init(reason: String) { auditReason = reason }

    /// The single translation point. Every error raised while verifying a login step goes through here.
    public static func translate(_ error: Error) -> AuthenticationFailed {
        switch error {
        case let e as PasskeyError: return AuthenticationFailed(reason: "passkey.\(e)")
        case let e as SecondFactorError: return AuthenticationFailed(reason: "second_factor.\(e)")
        default: return AuthenticationFailed(reason: "internal.\(type(of: error))")
        }
    }
}

/// Internal causes of a failed second factor (never public).
public enum SecondFactorError: Error, Equatable, Sendable {
    case noSession, wrongState, unknownAccount, noPasswordHash, passwordMismatch, accountInactive
}

/// Too many attempts; `Retry-After` in whole seconds (>= 1).
public struct RateLimited: PublicProblemError {
    public let retryAfter: Int
    public init(retryAfterSeconds: Int) { retryAfter = max(1, retryAfterSeconds) }
    public var statusCode: UInt { 429 }
    public var code: String { "rate_limited" }
    public var message: String { "Zu viele Anfragen. Bitte später erneut versuchen." }
    public var extraHeaders: [(name: String, value: String)] { [("Retry-After", String(retryAfter))] }
}

/// Dependency (database, key source) unavailable.
public struct ServiceUnavailable: PublicProblemError {
    public let retryAfter: Int?
    public init(retryAfterSeconds: Int? = nil) { retryAfter = retryAfterSeconds }
    public var statusCode: UInt { 503 }
    public var code: String { "unavailable" }
    public var message: String { "Dienst vorübergehend nicht verfügbar." }
    public var extraHeaders: [(name: String, value: String)] { retryAfter.map { [("Retry-After", String($0))] } ?? [] }
}

/// 409: the passkey step-up is not available under this listener policy (password/second factor required); the client
/// falls back to the full login. Says nothing about the account or credential.
public struct StepUpUnavailable: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 409 }
    public var code: String { "second_factor_required" }
    public var message: String { "Bitte melden Sie sich erneut vollständig an." }
}

/// 403: the action needs a fresh authentication (<= 5 min, anmeldung.md); the client must re-authenticate first.
public struct ReauthenticationRequired: PublicProblemError {
    public init() {}
    public var statusCode: UInt { 403 }
    public var code: String { "reauthentication_required" }
    public var message: String { "Bitte erneut anmelden, um diese Aktion zu bestätigen." }
}

