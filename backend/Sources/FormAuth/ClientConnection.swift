// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NIOCore
import Vapor
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private struct ListenerPortsKey: StorageKey { typealias Value = Set<Int> }
private struct ConnectionProbeKey: StorageKey { typealias Value = @Sendable (Request) -> Bool }

public extension Application {
    /// TCP ports of the listeners of this process (set by the server setup); used to tell the connection of a request apart from other sockets of
    /// the same peer. Empty = every local port.
    var listenerPorts: Set<Int> {
        get { storage[ListenerPortsKey.self] ?? [] }
        set { storage[ListenerPortsKey.self] = newValue }
    }
    /// Replaces the connection check (tests of the cancel path without a real socket); nil = the real check `ClientConnection.isOpen`.
    var connectionProbe: (@Sendable (Request) -> Bool)? {
        get { storage[ConnectionProbeKey.self] }
        set { storage[ConnectionProbeKey.self] = newValue }
    }
}

/// Is the client connection of a request still open? Vapor 4 reports neither a cancelled request nor (while nobody reads the body, i.e. while the
/// request waits in the body-budget queue) the end of the connection, and offers no per-connection pipeline hook (card 01480C4B). The question is
/// therefore put to the kernel: the socket of the request is found among the process's descriptors by its peer address and its TCP state is read
/// (`TCP_INFO` on Linux, `TCP_CONNECTION_INFO` on macOS). Only ESTABLISHED counts as open: a FIN or RST of the client (also with the request body
/// still unread in the socket buffer) turns it into CLOSE_WAIT/CLOSED; a socket that is gone is closed. Unknown (no remote address, e.g. in-memory
/// test transports) counts as open.
public enum ClientConnection {
    public static func isOpen(_ req: Request) -> Bool {
        if let probe = req.application.connectionProbe { return probe(req) }
        guard let remote = req.remoteAddress, let ip = remote.ipAddress, let port = remote.port else { return true }
        return PeerSocket.isEstablished(peerIP: ip, peerPort: port, localPorts: req.application.listenerPorts)
    }

    /// Open now and for `grace` seconds afterwards (a FIN that follows the last body byte may arrive a moment after it was read).
    public static func staysOpen(_ req: Request, grace: TimeInterval = 0.1) async -> Bool {
        let end = Date().addingTimeInterval(grace)
        repeat {
            if !isOpen(req) { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        } while Date() < end
        return isOpen(req)
    }
}

/// Finds the accepted socket of a peer and reads its TCP state. The descriptor is cached per peer and verified on every use (getpeername), so a
/// descriptor number that was closed and reused by another connection is never mistaken for the original.
enum PeerSocket {
    private static let cache = NSLock()
    nonisolated(unsafe) private static var known: [String: Int32] = [:]

    static func isEstablished(peerIP: String, peerPort: Int, localPorts: Set<Int>) -> Bool {
        let key = "\(peerIP)|\(peerPort)|\(localPorts.sorted())"
        cache.lock(); let cached = known[key]; cache.unlock()
        if let fd = cached, matches(fd, peerIP, peerPort, localPorts) { return state(fd) == establishedState }
        guard let fd = find(peerIP, peerPort, localPorts) else {
            cache.lock(); known[key] = nil; cache.unlock()
            return false   // the socket does not exist any more: the connection is closed
        }
        cache.lock(); known[key] = fd; if known.count > 4096 { known = [key: fd] }; cache.unlock()
        return state(fd) == establishedState
    }

    #if os(Linux)
    private static let establishedState: UInt8 = 1          // TCP_ESTABLISHED
    private static let infoOption: Int32 = 11               // TCP_INFO
    private static let fdDirectory = "/proc/self/fd"
    #else
    private static let establishedState: UInt8 = 4          // TCPS_ESTABLISHED
    private static let infoOption: Int32 = 0x106            // TCP_CONNECTION_INFO
    private static let fdDirectory = "/dev/fd"
    #endif

    /// First byte of struct tcp_info / tcp_connection_info is tcpi_state on both systems; 0 = could not be read.
    private static func state(_ fd: Int32) -> UInt8 {
        var buf = [UInt8](repeating: 0, count: 512)
        var len = socklen_t(buf.count)
        let rc = buf.withUnsafeMutableBytes { getsockopt(fd, Int32(IPPROTO_TCP), infoOption, $0.baseAddress, &len) }
        return rc == 0 && len > 0 ? buf[0] : 0
    }

    private static func endpoint(_ fd: Int32, peer: Bool) -> (ip: String, port: Int)? {
        var storage = sockaddr_storage(); var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let rc = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { peer ? getpeername(fd, $0, &len) : getsockname(fd, $0, &len) }
        }
        guard rc == 0 else { return nil }
        var host = [CChar](repeating: 0, count: 64)
        switch Int32(storage.ss_family) {
        case AF_INET:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                    var addr = a.pointee.sin_addr
                    guard inet_ntop(AF_INET, &addr, &host, socklen_t(host.count)) != nil else { return nil }
                    return (String(cString: host), Int(UInt16(bigEndian: a.pointee.sin_port)))
                }
            }
        case AF_INET6:
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                    var addr = a.pointee.sin6_addr
                    guard inet_ntop(AF_INET6, &addr, &host, socklen_t(host.count)) != nil else { return nil }
                    return (String(cString: host), Int(UInt16(bigEndian: a.pointee.sin6_port)))
                }
            }
        default: return nil
        }
    }

    private static func matches(_ fd: Int32, _ ip: String, _ port: Int, _ localPorts: Set<Int>) -> Bool {
        guard let p = endpoint(fd, peer: true), p.ip == ip, p.port == port else { return false }
        if localPorts.isEmpty { return true }
        guard let l = endpoint(fd, peer: false) else { return false }
        return localPorts.contains(l.port)
    }

    private static func find(_ ip: String, _ port: Int, _ localPorts: Set<Int>) -> Int32? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: fdDirectory) else { return nil }
        for name in names {
            guard let fd = Int32(name), matches(fd, ip, port, localPorts) else { continue }
            return fd
        }
        return nil
    }
}
