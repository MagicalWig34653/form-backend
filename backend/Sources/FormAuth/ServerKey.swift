// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation

/// 32-byte server key from the operating environment (ADR 0008 F5), used to protect CSRF secrets (AEAD) and
/// to pseudonymise throttle subjects (HMAC). The source (file/environment, outside DB and repo) is kept behind
/// this protocol; the concrete provider is decided with D9.
public protocol ServerKeyProvider: Sendable {
    func serverKey() async throws -> SymmetricKey
}

public struct StaticServerKey: ServerKeyProvider {
    private let bytes: Data
    /// - Throws: if the key is not exactly 32 bytes.
    public init(_ bytes: Data) throws {
        guard bytes.count == 32 else { throw ServerKeyError.wrongLength }
        self.bytes = bytes
    }
    public func serverKey() async throws -> SymmetricKey { SymmetricKey(data: bytes) }
}

public enum ServerKeyError: Error, Equatable { case wrongLength }

/// Domain-separated sub-keys so one purpose can never be replayed as another.
enum KeyPurpose: String {
    case csrf = "form-backend/csrf/v1"
    case throttle = "form-backend/throttle/v1"
    case secrets = "form-backend/managed-secrets/v1"

    func derive(from master: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(rawValue.utf8), outputByteCount: 32)
    }
}

/// Reads the server key once from a file (64 hex characters, optional trailing newline). The file must not be
/// readable by group/others; the key never appears in logs or errors.
public struct FileServerKey: ServerKeyProvider {
    private let key: StaticServerKey

    public enum LoadError: Error, Equatable { case unreadable, permissions, format }

    public init(path: String) throws {
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw LoadError.unreadable }
        guard st.st_mode & 0o077 == 0 else { throw LoadError.permissions }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else { throw LoadError.unreadable }
        let hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.utf8.count == 64, let bytes = Data(hexString: hex) else { throw LoadError.format }
        key = try StaticServerKey(bytes)
    }

    public func serverKey() async throws -> SymmetricKey { try await key.serverKey() }
}

extension Data {
    init?(hexString s: String) {
        guard s.utf8.count % 2 == 0 else { return nil }
        var out = Data(); var it = s.utf8.makeIterator()
        func nib(_ c: UInt8) -> UInt8? { switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return nil } }
        while let a = it.next(), let b = it.next() {
            guard let x = nib(a), let y = nib(b) else { return nil }
            out.append(x << 4 | y)
        }
        self = out
    }
}
