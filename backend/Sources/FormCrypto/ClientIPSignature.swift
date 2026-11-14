// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Signed visitor address (ADR 0047). The SDK runs on the customer's web server, so the backend only sees that server's
/// address; the SDK therefore names the visitor and signs the claim with the form's Ed25519 key. The signed text binds
/// the form, the claimed address, the request timestamp and the request signature itself (which in turn covers method,
/// route, form, timestamp and body hash): a captured claim cannot be attached to another request or another address, and
/// it is exactly as fresh as the request (`RequestSignature.validTimestamp`, +-300 s).
public enum ClientIPSignature {
    public static let ipHeader = "X-Kubus-Client-IP"
    public static let signatureHeader = "X-Kubus-Client-IP-Signature"

    public static func signingText(formID: String, ip: String, timestamp: String, requestSignature: String) -> Data {
        Data("KUBUS-CLIENT-IP-V1\n\(formID)\n\(ip)\n\(timestamp)\n\(requestSignature)".utf8)
    }

    public static func sign(formID: String, ip: String, timestamp: String, requestSignature: String, seed: Data) throws -> Data {
        try RequestSignature.sign(signingText(formID: formID, ip: ip, timestamp: timestamp, requestSignature: requestSignature), seed: seed)
    }

    public static func verify(signature: Data, formID: String, ip: String, timestamp: String, requestSignature: String, publicKey: Data, now: Int64) -> Bool {
        guard signature.count == 64, ip.utf8.count <= 45, RequestSignature.validTimestamp(timestamp, now: now) else { return false }
        return Ed25519Strict.isValidSignature(signature, for: signingText(formID: formID, ip: ip, timestamp: timestamp, requestSignature: requestSignature), publicKey: publicKey)
    }
}
