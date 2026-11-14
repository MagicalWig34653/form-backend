// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Plain TCP client for tests of connection ends (card 01480C4B): gives a complete request to the kernel at once (large send buffer, so it
/// does not matter that the server does not read) and closes the connection without reading anything, like a client that gave up.
public final class RawClient: @unchecked Sendable {
    public let fd: Int32
    public private(set) var localPort = 0

    public init(host: String = "127.0.0.1", port: Int) throws {
        #if os(Linux)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for size in [16 << 20, 8 << 20, 4 << 20] {
            var big = Int32(size)
            if setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &big, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(port).bigEndian; addr.sin_addr.s_addr = inet_addr(host)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard rc == 0 else { RawClient.closeFD(fd); throw POSIXError(.ECONNREFUSED) }
        var local = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        localPort = Int(UInt16(bigEndian: local.sin_port))
    }

    /// Sends everything within `seconds`; returns the bytes the kernel accepted.
    @discardableResult public func send(_ data: Data, seconds: Int = 10) -> Int {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var sent = 0
        data.withUnsafeBytes { raw in
            while sent < data.count {
                let n = Foundation.send(fd, raw.baseAddress! + sent, min(1 << 20, data.count - sent), 0)
                if n <= 0 { break }
                sent += n
            }
        }
        return sent
    }

    public func close() { RawClient.closeFD(fd) }

    /// Aborts with a TCP reset (SO_LINGER 0): unsent data is discarded and the peer sees the end of the connection at once.
    public func reset() {
        var l = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
        close()
    }

    private static func closeFD(_ fd: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }
}
