// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A parsed IPv4/IPv6 address as 16 bytes (IPv4 and IPv4-mapped IPv6 are both stored as mapped), so comparisons and
/// throttle keys are canonical regardless of the textual form.
public struct IPAddr: Hashable, Sendable {
    public let bytes: [UInt8]   // always 16

    public init?(_ text: String) {
        var v6 = in6_addr()
        if text.contains(":") {
            guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
            bytes = withUnsafeBytes(of: v6) { Array($0) }
        } else {
            var v4 = in_addr()
            guard inet_pton(AF_INET, text, &v4) == 1 else { return nil }
            bytes = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF] + withUnsafeBytes(of: v4) { Array($0) }
        }
    }

    /// Canonical text: dotted quad for IPv4 (incl. mapped), compressed form for IPv6.
    public var text: String {
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
            return bytes[12...].map(String.init).joined(separator: ".")
        }
        var v6 = in6_addr()
        withUnsafeMutableBytes(of: &v6) { $0.copyBytes(from: bytes) }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(AF_INET6, &v6, &buf, socklen_t(buf.count)) != nil ? String(cString: buf) : "invalid"
    }
}

extension IPAddr {
    /// Key for per-client quotas: IPv4 (incl. mapped) as is; native IPv6 reduced to its /64 prefix, because one subscriber
    /// normally controls a whole /64 and could otherwise rotate through 2^64 addresses. Unparseable input stays unchanged.
    public static func quotaKey(_ text: String) -> String {
        guard let ip = IPAddr(text) else { return text }
        if ip.bytes[0..<10].allSatisfy({ $0 == 0 }) && ip.bytes[10] == 0xFF && ip.bytes[11] == 0xFF { return ip.text }
        return IPAddr(bytes: CIDR.mask(ip.bytes, 64)).text + "/64"
    }
    init(bytes: [UInt8]) { self.bytes = bytes }
}

/// `a.b.c.d/n` or `x::/n` (a bare address means /32 or /128).
public struct CIDR: Sendable, Equatable {
    let network: [UInt8]
    let prefix: Int   // over the 128-bit mapped form

    public init?(_ text: String) {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, let ip = IPAddr(parts[0]) else { return nil }
        let isV4 = !parts[0].contains(":")
        let maxBits = isV4 ? 32 : 128
        var bits = maxBits
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(parts[1]), (0...maxBits).contains(n) else { return nil }
            bits = n
        }
        prefix = isV4 ? 96 + bits : bits
        network = CIDR.mask(ip.bytes, prefix)
    }

    static func mask(_ b: [UInt8], _ prefix: Int) -> [UInt8] {
        var out = b
        for i in 0..<16 {
            let keep = max(0, min(8, prefix - i * 8))
            out[i] &= keep == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
        }
        return out
    }

    public func contains(_ ip: IPAddr) -> Bool { CIDR.mask(ip.bytes, prefix) == network }
}

/// Client address for throttling and audit. The TCP peer is used unless it is a trusted proxy; then `X-Forwarded-For`
/// is read from the right and the first hop that is NOT a trusted proxy is the client (the left part is client-controlled
/// and ignored). Any malformed entry on the way makes the result fall back to the peer (never to a spoofable value).
public struct ClientIPResolver: Sendable {
    public let trusted: [CIDR]
    public init(trusted: [CIDR]) { self.trusted = trusted }

    func isTrusted(_ ip: IPAddr) -> Bool { trusted.contains { $0.contains(ip) } }

    public func resolve(peer: String?, forwardedFor: String?) -> String {
        guard let peer, let peerIP = IPAddr(peer) else { return "unknown" }
        guard !trusted.isEmpty, isTrusted(peerIP), let xff = forwardedFor, !xff.isEmpty else { return peerIP.text }
        let hops = xff.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard hops.count <= 20 else { return peerIP.text }
        var leftmost: IPAddr?
        for hop in hops.reversed() {
            guard let ip = IPAddr(hop) else { return peerIP.text }
            if !isTrusted(ip) { return ip.text }
            leftmost = ip
        }
        return leftmost?.text ?? peerIP.text   // every hop is a trusted proxy: the original client is inside the trusted network
    }
}
