// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto

/// Strict Ed25519 verification (contract signatur.md "Ed25519-Strenge (A7)").
/// CryptoKit / swift-crypto (BoringSSL) do not document rejection of malleable signatures or
/// small-order points, so these checks run BEFORE the library verification and never fall back:
///  - signature exactly 64 bytes, public key exactly 32 bytes
///  - S < L (little-endian scalar canonical)
///  - R and A: y-coordinate < p (canonical encoding), not of small order (blocklist of the
///    8 small-order points; their canonical y values, both sign bits)
public enum Ed25519Strict {
    /// L = 2^252 + 27742317777372353535851937790883648493, little-endian.
    static let order: [UInt8] = [
        0xed, 0xd3, 0xf5, 0x5c, 0x1a, 0x63, 0x12, 0x58, 0xd6, 0x9c, 0xf7, 0xa2, 0xde, 0xf9, 0xde, 0x14,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x10,
    ]
    /// y values (sign bit cleared) of the small-order points: orders 1, 2, 4 (y=0) and 8 (two values).
    static let smallOrderY: [[UInt8]] = [
        [UInt8](repeating: 0, count: 32),
        [1] + [UInt8](repeating: 0, count: 31),
        [0xec] + [UInt8](repeating: 0xff, count: 30) + [0x7f],
        [0xc7, 0x17, 0x6a, 0x70, 0x3d, 0x4d, 0xd8, 0x4f, 0xba, 0x3c, 0x0b, 0x76, 0x0d, 0x10, 0x67, 0x0f,
         0x2a, 0x20, 0x53, 0xfa, 0x2c, 0x39, 0xcc, 0xc6, 0x4e, 0xc7, 0xfd, 0x77, 0x92, 0xac, 0x03, 0x7a],
        [0x26, 0xe8, 0x95, 0x8f, 0xc2, 0xb2, 0x27, 0xb0, 0x45, 0xc3, 0xf4, 0x89, 0xf2, 0xef, 0x98, 0xf0,
         0xd5, 0xdf, 0xac, 0x05, 0xd3, 0xc6, 0x33, 0x39, 0xb1, 0x38, 0x02, 0x88, 0x6d, 0x53, 0xfc, 0x05],
    ]

    /// a < b for equal-length little-endian integers.
    static func lessThan(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] < b[i] }
        return false
    }
    static func yCoordinate(_ point: [UInt8]) -> [UInt8] { var y = point; y[31] &= 0x7f; return y }
    static func isCanonicalPoint(_ point: [UInt8]) -> Bool {
        // p = 2^255 - 19; y >= p iff y bytes are ed ff..ff 7f or larger in the low byte.
        let p = [0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f]
        return lessThan(yCoordinate(point), p)
    }
    static func hasSmallOrder(_ point: [UInt8]) -> Bool { smallOrderY.contains(yCoordinate(point)) }

    public static func isValidSignature(_ signature: Data, for message: Data, publicKey: Data) -> Bool {
        guard signature.count == 64, publicKey.count == 32 else { return false }
        let sig = [UInt8](signature), a = [UInt8](publicKey)
        let r = Array(sig[0..<32]), s = Array(sig[32..<64])
        guard lessThan(s, order),
              isCanonicalPoint(r), !hasSmallOrder(r),
              isCanonicalPoint(a), !hasSmallOrder(a),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
