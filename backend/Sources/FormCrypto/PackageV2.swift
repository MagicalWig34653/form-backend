// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

public struct PackageV2 {
    public let kid: String
    public let wrap: String
    public let a: Data
    public let b: Data
    public let iv: Data
    public let ciphertext: Data
    public let tag: Data
    public init(_ wire: String) throws {
        let p = wire.components(separatedBy: "|")
        guard p.count == 7, p[0] == "KUBUS-AEAD:2", p[1].utf8.count == 16,
              p[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), ["hpke", "sym"].contains(p[2]) else { throw FormCryptoError.format }
        let w = p[3].components(separatedBy: ":")
        guard w.count == 2 else { throw FormCryptoError.format }
        func decode(_ s: String, length: Int? = nil) throws -> Data {
            guard let d = Data(base64Encoded: s), d.base64EncodedString() == s, length == nil || d.count == length else { throw FormCryptoError.format }
            return d
        }
        kid = p[1]; wrap = p[2]
        a = try decode(w[0], length: wrap == "hpke" ? 32 : 12); b = try decode(w[1], length: 48)
        iv = try decode(p[4], length: 12); ciphertext = try decode(p[5]); tag = try decode(p[6], length: 16)
    }
    public var wire: String { "KUBUS-AEAD:2|\(kid)|\(wrap)|\(a.base64EncodedString()):\(b.base64EncodedString())|\(iv.base64EncodedString())|\(ciphertext.base64EncodedString())|\(tag.base64EncodedString())" }
    public static func seal(_ plaintext: Data, recipient: Data) throws -> PackageV2 {
        let cek = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let iv = AES.GCM.Nonce().withUnsafeBytes { Data($0) }
        return try seal(plaintext, recipient: recipient, cek: cek, iv: iv, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }
    static func seal(_ plaintext: Data, recipient: Data, cek: Data, iv: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> PackageV2 {
        guard cek.count == 32 else { throw FormCryptoError.format }
        let kid = try keyID(recipient)
        let wrapped = try HPKE.seal(cek, recipient: recipient, info: bytes("kubus-anfrage v2"), aad: bytes(kid), ephemeral: ephemeral)
        let payload = try sealGCM(plaintext, key: cek, nonce: iv, aad: bytes("KUBUS-AEAD:2"))
        return try PackageV2("KUBUS-AEAD:2|\(kid)|hpke|\(wrapped.enc.base64EncodedString()):\(wrapped.ciphertext.base64EncodedString())|\(iv.base64EncodedString())|\(payload.dropLast(16).base64EncodedString())|\(payload.suffix(16).base64EncodedString())")
    }
    /// Opens the payload with an already unwrapped content key (the browser's `originalProof`); the wrap is not involved.
    public func open(withCEK cek: Data) throws -> Data {
        guard cek.count == 32 else { throw FormCryptoError.format }
        return try openGCM(ciphertext + tag, key: cek, nonce: iv, aad: bytes("KUBUS-AEAD:2"))
    }
    // Decryption is a client/test primitive, never a server authorization path.
    public func open(recipient: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard try keyID(recipient.publicKey.rawRepresentation) == kid else { throw FormCryptoError.keyMismatch }
        let cek: Data
        if wrap == "hpke" {
            cek = try HPKE.open(b, enc: a, recipient: recipient, info: bytes("kubus-anfrage v2"), aad: bytes(kid))
        } else {
            let kek = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: recipient.rawRepresentation), salt: Data(), info: bytes("kubus-langzeit v1"), outputByteCount: 32).withUnsafeBytes { Data($0) }
            cek = try openGCM(b, key: kek, nonce: a, aad: bytes(kid))
        }
        guard cek.count == 32 else { throw FormCryptoError.format }
        return try openGCM(ciphertext + tag, key: cek, nonce: iv, aad: bytes("KUBUS-AEAD:2"))
    }
}
