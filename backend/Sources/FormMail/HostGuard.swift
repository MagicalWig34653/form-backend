// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import NIOCore
import NIOPosix
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Connection targets of outgoing mail (SSRF defence in depth): the host is resolved HERE, every resulting address must be
/// outside the blocked ranges (or inside an explicitly allowed network), and the caller connects to the checked literal
/// address, so DNS cannot change the answer between check and use.
public enum HostGuard {
    public static let blocked: [CIDR] = ([
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
        "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
        "::/128", "::1/128", "64:ff9b::/96", "100::/64", "2001:db8::/32", "fc00::/7", "fe80::/10", "ff00::/8",
    ] as [String]).compactMap { CIDR($0) }

    public enum Failure: Error, Equatable { case unresolvable, blocked, timeout }

    public static func isAllowed(_ ip: IPAddr, allowedNets: [CIDR]) -> Bool {
        allowedNets.contains { $0.contains(ip) } || !blocked.contains { $0.contains(ip) }
    }

    /// Checked address literals for `host` (IPv4 first). Every address must pass the selected policy.
    /// `requireAllowedNetwork` denies empty allowlists and addresses outside them, including public IPs.
    public static func resolve(host: String, allowedNets: [CIDR], resolver: BoundedDNSResolver = .shared, requireAllowedNetwork: Bool = false) async throws -> [String] {
        // Migration is opt-in only; SMTP/webhooks retain their public-address policy.
        if requireAllowedNetwork && allowedNets.isEmpty { throw Failure.blocked }
        let addrs = try await resolver.resolve(host)
        guard !addrs.isEmpty else { throw Failure.unresolvable }
        // A name that maps to both public and blocked addresses is refused as a whole (rebinding-style answers).
        guard addrs.allSatisfy({ ip in
            requireAllowedNetwork ? allowedNets.contains { $0.contains(ip) } : isAllowed(ip, allowedNets: allowedNets)
        }) else { throw Failure.blocked }
        return addrs.map(\.text)
    }

    static func lookup(_ host: String) throws -> [IPAddr] {
        if let literal = IPAddr(host) { return [literal] }
        guard host.utf8.count <= 253, host.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else { throw Failure.unresolvable }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { throw Failure.unresolvable }
        defer { freeaddrinfo(first) }
        var out: [IPAddr] = [], p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var a = $0.pointee.sin_addr; inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) }
            } else if ai.pointee.ai_family == AF_INET6, let sa = ai.pointee.ai_addr {
                sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { var a = $0.pointee.sin6_addr; inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)) }
            }
            if let ip = IPAddr(String(cString: buf)), !out.contains(ip) { out.append(ip) }
            p = ai.pointee.ai_next
        }
        return out.sorted { !$0.text.contains(":") && $1.text.contains(":") }
    }
}

/// No unbounded queue: timed-out libc calls retain their slot until they actually return.
/// Even a permanently stuck OS resolver can occupy at most four dedicated threads.
public final class BoundedDNSResolver: @unchecked Sendable {
    public static let shared = BoundedDNSResolver()
    private let pool: NIOThreadPool
    private let lock = NSLock()
    private var active = 0
    private let capacity: Int
    private let deadline: TimeAmount
    private let lookup: @Sendable (String) throws -> [IPAddr]
    public init(capacity: Int = 4, deadline: TimeAmount = .seconds(3),
                lookup: (@Sendable (String) throws -> [IPAddr])? = nil) {
        self.capacity = max(1, capacity); self.deadline = deadline; self.lookup = lookup ?? { try HostGuard.lookup($0) }
        pool = NIOThreadPool(numberOfThreads: max(1, capacity)); pool.start()
    }
    deinit { pool.shutdownGracefully { _ in } }
    private func admit() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active < capacity else { return false }; active += 1; return true
    }
    private func release() { lock.lock(); active -= 1; lock.unlock() }
    public func resolve(_ host: String) async throws -> [IPAddr] {
        if let literal = IPAddr(host) { return [literal] }
        guard admit() else { throw HostGuard.Failure.timeout }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let promise = loop.makePromise(of: [IPAddr].self)
        // All completion races are serialized on this event loop.
        let completion = DNSCompletion(promise)
        let timer = loop.scheduleTask(in: deadline) { completion.complete(.failure(HostGuard.Failure.timeout)) }
        pool.runIfActive(eventLoop: loop) { [self] in
            defer { release() }
            return try lookup(host)
        }.whenComplete { result in
            timer.cancel(); completion.complete(result)
        }
        return try await promise.futureResult.get()
    }
}
private final class DNSCompletion: @unchecked Sendable {
    let promise: EventLoopPromise<[IPAddr]>
    var done = false
    init(_ promise: EventLoopPromise<[IPAddr]>) { self.promise = promise }
    func complete(_ result: Result<[IPAddr], Error>) {
        guard !done else { return }; done = true; promise.completeWith(result)
    }
}
