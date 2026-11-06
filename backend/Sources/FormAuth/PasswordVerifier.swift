// SPDX-License-Identifier: AGPL-3.0-only
import argon2
import Foundation
import Vapor

/// Checks the password of the second factor. Contract target is Argon2id (ADR 0008 F4); legacy bcrypt hashes
/// (`$2y$`/`$2a$`/`$2b$`, e.g. from PHP `password_hash` in the old backend) stay verifiable until they are re-hashed.
/// Callers never depend on the algorithm.
public protocol PasswordVerifier: Sendable {
    /// Always performs a hash computation, also for `hash == nil` (equivalent dummy path against timing oracles).
    func verify(password: String, hash: String?) async -> Bool
}

/// Argon2id parameters. Defaults are the OWASP minimum profile (19 MiB, t=2, p=1); the contract says "Parameter nach
/// Messung" (anmeldung.md), so tune on the target hardware before production.
public struct Argon2Parameters: Sendable, Equatable {
    public var memoryKiB: UInt32 = 19_456
    public var iterations: UInt32 = 2
    public var parallelism: UInt32 = 1
    public var saltBytes = 16
    public var hashBytes = 32
    public init() {}
}

public enum Argon2id {
    /// PHC string `$argon2id$v=19$m=…,t=…,p=…$salt$hash` (same format as PHP `password_hash(..., PASSWORD_ARGON2ID)`).
    public static func hash(_ password: String, parameters: Argon2Parameters = Argon2Parameters()) throws -> String {
        let salt = [UInt8]((0..<parameters.saltBytes).map { _ in UInt8.random(in: 0...255) })
        let pwd = Array(password.utf8)
        let length = argon2_encodedlen(parameters.iterations, parameters.memoryKiB, parameters.parallelism, UInt32(salt.count), UInt32(parameters.hashBytes), Argon2_id)
        var out = [CChar](repeating: 0, count: length)
        let rc = argon2id_hash_encoded(parameters.iterations, parameters.memoryKiB, parameters.parallelism, pwd, pwd.count, salt, salt.count, parameters.hashBytes, &out, out.count)
        guard rc == ARGON2_OK.rawValue else { throw Argon2Error.hashFailed }
        return String(cString: out)
    }

    /// True only for a well-formed `$argon2id$` string that matches. Malformed or other-variant strings are false.
    public static func verify(_ password: String, encoded: String) -> Bool {
        guard encoded.hasPrefix("$argon2id$") else { return false }
        let pwd = Array(password.utf8)
        return argon2id_verify(encoded, pwd, pwd.count) == ARGON2_OK.rawValue
    }

    /// Cost of an encoded hash, nil if it is not a parsable argon2id string.
    public static func parameters(of encoded: String) -> Argon2Parameters? {
        // $argon2id$v=19$m=19456,t=2,p=1$salt$hash
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5, parts[0] == "argon2id", parts[1] == "v=19" else { return nil }
        var p = Argon2Parameters()
        for kv in parts[2].split(separator: ",") {
            let pair = kv.split(separator: "=")
            guard pair.count == 2, let n = UInt32(pair[1]) else { return nil }
            switch pair[0] { case "m": p.memoryKiB = n; case "t": p.iterations = n; case "p": p.parallelism = n; default: return nil }
        }
        return p
    }

    /// True if the hash is not Argon2id or uses weaker parameters than `target` (re-hash after a successful login).
    public static func needsRehash(_ encoded: String, target: Argon2Parameters = Argon2Parameters()) -> Bool {
        guard let p = parameters(of: encoded) else { return true }
        return p.memoryKiB < target.memoryKiB || p.iterations < target.iterations || p.parallelism != target.parallelism
    }
}

public enum Argon2Error: Error, Equatable { case hashFailed }

/// Argon2id for new hashes, bcrypt accepted for legacy ones. Dispatch is by hash prefix only.
public struct DefaultPasswordVerifier: PasswordVerifier {
    private let dummy: String
    public init(parameters: Argon2Parameters = Argon2Parameters()) {
        dummy = (try? Argon2id.hash("dummy-password-not-in-use", parameters: parameters)) ?? ""
    }

    public func verify(password: String, hash: String?) async -> Bool {
        guard let hash, !hash.isEmpty else {
            _ = Argon2id.verify(password, encoded: dummy)   // equivalent work, result discarded
            return false
        }
        if hash.hasPrefix("$argon2id$") { return Argon2id.verify(password, encoded: hash) }
        if hash.hasPrefix("$2y$") || hash.hasPrefix("$2a$") || hash.hasPrefix("$2b$") { return BcryptVerifier.verifyLegacy(password, hash) }
        _ = Argon2id.verify(password, encoded: dummy)       // unknown format: fail closed with the same cost
        return false
    }
}

public struct BcryptVerifier: PasswordVerifier {
    public init() {}
    private static let dummy: String = (try? Bcrypt.hash("dummy-password-not-in-use", cost: 12)) ?? ""

    static func verifyLegacy(_ password: String, _ hash: String) -> Bool { (try? Bcrypt.verify(password, created: hash)) ?? false }

    public func verify(password: String, hash: String?) async -> Bool {
        let h = hash ?? Self.dummy
        let ok = (try? Bcrypt.verify(password, created: h)) ?? false
        return hash != nil && ok
    }
}
