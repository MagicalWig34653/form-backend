// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

public enum FormCryptoError: Error { case format, keyMismatch, unsupportedPHPType, depthExceeded }

extension Data {
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
    public init(hex: String) throws {
        guard hex.count.isMultiple(of: 2) else { throw FormCryptoError.format }
        var bytes = [UInt8](); var i = hex.startIndex
        while i < hex.endIndex {
            let end = hex.index(i, offsetBy: 2)
            guard hex[i..<end].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
                  let b = UInt8(hex[i..<end], radix: 16) else { throw FormCryptoError.format }
            bytes.append(b); i = end
        }
        self.init(bytes)
    }
}
func bytes(_ s: String) -> Data { Data(s.utf8) }
public func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
public func keyID(_ publicKey: Data) throws -> String {
    guard publicKey.count == 32 else { throw FormCryptoError.format }
    return String(sha256(publicKey).hex.prefix(16))
}
func extract(_ salt: Data, _ input: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: salt.isEmpty ? Data(repeating: 0, count: 32) : salt)))
}
func expand(_ prk: Data, _ info: Data, _ length: Int) -> Data {
    var output = Data(); var t = Data()
    for i in 1...((length + 31) / 32) {
        t = Data(HMAC<SHA256>.authenticationCode(for: t + info + Data([UInt8(i)]), using: SymmetricKey(data: prk)))
        output += t
    }
    return output.prefix(length)
}
func sealGCM(_ plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
    guard key.count == 32, nonce.count == 12 else { throw FormCryptoError.format }
    let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
    return box.ciphertext + box.tag
}
func openGCM(_ ciphertext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
    guard key.count == 32, nonce.count == 12, ciphertext.count >= 16 else { throw FormCryptoError.format }
    return try AES.GCM.open(AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16)), using: SymmetricKey(data: key), authenticating: aad)
}

// Single-shot base mode, sequence 0 only. No reusable nonce/context API.
public enum HPKE {
    static let kem = bytes("KEM") + Data([0, 32])
    static let suite = bytes("HPKE") + Data([0, 32, 0, 1, 0, 2])
    static func labeledExtract(_ suite: Data, _ salt: Data, _ label: String, _ input: Data) -> Data {
        extract(salt, bytes("HPKE-v1") + suite + bytes(label) + input)
    }
    static func labeledExpand(_ suite: Data, _ prk: Data, _ label: String, _ info: Data, _ length: Int) -> Data {
        expand(prk, Data([UInt8(length >> 8), UInt8(length & 255)]) + bytes("HPKE-v1") + suite + bytes(label) + info, length)
    }
    struct Schedule { let shared: Data; let context: Data; let key: Data; let nonce: Data }
    static func schedule(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data, enc: Data, recipient: Data, info: Data) throws -> Schedule {
        let dh = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)).withUnsafeBytes { Data($0) }
        guard dh.contains(where: { $0 != 0 }) else { throw FormCryptoError.format }
        let prk = labeledExtract(kem, Data(), "eae_prk", dh)
        let shared = labeledExpand(kem, prk, "shared_secret", enc + recipient, 32)
        let context = Data([0]) + labeledExtract(suite, Data(), "psk_id_hash", Data()) + labeledExtract(suite, Data(), "info_hash", info)
        let secret = labeledExtract(suite, shared, "secret", Data())
        return Schedule(shared: shared, context: context, key: labeledExpand(suite, secret, "key", context, 32), nonce: labeledExpand(suite, secret, "base_nonce", context, 12))
    }
    public static func seal(_ plaintext: Data, recipient: Data, info: Data, aad: Data) throws -> (enc: Data, ciphertext: Data) {
        try seal(plaintext, recipient: recipient, info: info, aad: aad, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }
    // Internal deterministic entry point is accessible only to tests.
    static func seal(_ plaintext: Data, recipient: Data, info: Data, aad: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws -> (enc: Data, ciphertext: Data) {
        let enc = ephemeral.publicKey.rawRepresentation
        let s = try schedule(privateKey: ephemeral, peer: recipient, enc: enc, recipient: recipient, info: info)
        return (enc, try sealGCM(plaintext, key: s.key, nonce: s.nonce, aad: aad))
    }
    public static func open(_ ciphertext: Data, enc: Data, recipient: Curve25519.KeyAgreement.PrivateKey, info: Data, aad: Data) throws -> Data {
        let s = try schedule(privateKey: recipient, peer: enc, enc: enc, recipient: recipient.publicKey.rawRepresentation, info: info)
        return try openGCM(ciphertext, key: s.key, nonce: s.nonce, aad: aad)
    }
}
