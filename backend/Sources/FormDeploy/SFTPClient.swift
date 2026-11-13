// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import FormCore
import FormMail
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

public struct SFTPConfig: Sendable, Equatable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    /// `SHA256:<base64 without padding>` exactly like `ssh-keygen -lf` prints it. REQUIRED: there is no trust-on-first-use.
    public var hostKeySHA256: String
    /// Per answer.
    public var timeout: TimeInterval
    /// Absolute limit for the whole session from `connect()` on (review Astra 2 M6).
    public var totalTimeout: TimeInterval
    public init(host: String, port: Int = 22, username: String, password: String, hostKeySHA256: String, timeout: TimeInterval = 30, totalTimeout: TimeInterval = 600) {
        self.host = host; self.port = port; self.username = username; self.password = password; self.hostKeySHA256 = hostKeySHA256; self.timeout = timeout
        self.totalTimeout = totalTimeout
    }
}

public enum SSHHostKey {
    /// `SHA256:…` fingerprint of an OpenSSH public key line (`ssh-ed25519 AAAA…`).
    public static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let line = String(openSSHPublicKey: key)
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
        let d = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + d
    }
    public static func isValid(_ fp: String) -> Bool { fp.range(of: "^SHA256:[A-Za-z0-9+/]{43}$", options: .regularExpression) != nil }
}

private final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let expected: String?
    private let lock = NSLock()
    private var _seen = ""
    var seen: String { lock.lock(); defer { lock.unlock() }; return _seen }
    private(set) var rejected = false
    init(expected: String?) { self.expected = expected }
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = SSHHostKey.fingerprint(hostKey)
        lock.lock(); _seen = fp; lock.unlock()
        if let expected, expected == fp { validationCompletePromise.succeed(()) }
        else if expected == nil { validationCompletePromise.fail(FTPError("host_key_probe")) }   // probe: remember what was offered, never authenticate
        else { lock.lock(); rejected = true; lock.unlock(); validationCompletePromise.fail(FTPError("host_key_mismatch")) }
    }
}

private final class PasswordAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let user: String, password: String
    private var tried = false
    private let lock = NSLock()
    private var _gaveUp = false
    var gaveUp: Bool { lock.lock(); defer { lock.unlock() }; return _gaveUp }
    init(user: String, password: String) { self.user = user; self.password = password }
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods, nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        guard !tried, availableMethods.contains(.password) else { lock.lock(); _gaveUp = true; lock.unlock(); nextChallengePromise.succeed(nil); return }   // one attempt, no guessing
        tried = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "ssh-connection", offer: .password(.init(password: password))))
    }
}

/// Collects the SFTP byte stream into whole packets (length-prefixed), bounded.
private final class SFTPPacketHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData
    private var pending = Data()
    private var failed = false
    let continuation: AsyncStream<Result<Data, FTPError>>.Continuation
    let backlog: ReplyBacklog
    init(_ c: AsyncStream<Result<Data, FTPError>>.Continuation, backlog: ReplyBacklog) { continuation = c; self.backlog = backlog }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        let d = unwrapInboundIn(data)
        guard case .channel = d.type, case .byteBuffer(var b) = d.data else { return }   // stderr (.stdErr) is ignored
        pending.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
        while pending.count >= 4 {
            let len = pending.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard len > 0, len <= 1 << 20 else { continuation.yield(.failure(FTPError("bad_reply"))); context.close(promise: nil); return }
            guard pending.count >= 4 + len else { break }
            // the client has one request in flight: a server that sends more than a few unread packets ends the session (review Astra 2 M6)
            guard backlog.received() else { failed = true; continuation.yield(.failure(FTPError("reply_overflow"))); continuation.finish(); context.close(promise: nil); return }
            continuation.yield(.success(pending.subdata(in: pending.startIndex + 4 ..< pending.startIndex + 4 + len)))
            pending = Data(pending.dropFirst(4 + len))
        }
    }
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { continuation.yield(.failure(FTPError("connection_error"))); context.close(promise: nil) }
}

/// SFTP (protocol version 3) over SSH, password authentication, pinned host key (ADR 0011). Sequential: one request in flight.
public final class SFTPClient: RemoteFileClient, @unchecked Sendable {
    let config: SFTPConfig?
    let probeHost: (host: String, port: Int)?
    let allowedNets: [CIDR]
    let group: EventLoopGroup
    private var root: Channel?
    private var session: Channel?
    private var packets: AsyncStream<Result<Data, FTPError>>.Iterator?
    private var nextID: UInt32 = 1
    private var timeout: TimeInterval = 30
    var timeoutForTests: TimeInterval { get { timeout } set { timeout = newValue } }
    private var deadline: Date?
    private var backlog = ReplyBacklog(limit: 4)

    public init(config: SFTPConfig, allowedNets: [CIDR] = [], group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config; self.probeHost = nil; self.allowedNets = allowedNets; self.group = group; self.timeout = config.timeout
    }

    /// Host key fingerprint a server offers (admin confirms it out of band before saving the connection). Authenticates nothing.
    public static func probe(host: String, port: Int, allowedNets: [CIDR] = [], group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> String {
        let addrs: [String]
        do { addrs = try await HostGuard.resolve(host: host, allowedNets: allowedNets) }
        catch HostGuard.Failure.blocked { throw FTPError("target_blocked") } catch { throw FTPError("unresolvable") }
        let pin = PinnedHostKey(expected: nil)
        do {
            let ch = try await ClientBootstrap(group: group).connectTimeout(.seconds(10)).channelInitializer { ch in
                ch.pipeline.addHandler(NIOSSHHandler(role: .client(.init(userAuthDelegate: PasswordAuth(user: "probe", password: ""), serverAuthDelegate: pin)), allocator: ch.allocator, inboundChildChannelInitializer: nil))
            }.connect(host: addrs[0], port: port).get()
            for _ in 0..<50 where pin.seen.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
            try? await ch.close()
        } catch { if pin.seen.isEmpty { throw FTPError("connect_failed") } }
        guard SSHHostKey.isValid(pin.seen) else { throw FTPError("host_key_unavailable") }
        return pin.seen
    }

    // MARK: session

    public func connect() async throws {
        guard let config else { throw FTPError("not_configured") }
        guard SSHHostKey.isValid(config.hostKeySHA256) else { throw FTPError("host_key_missing") }
        let until = Date().addingTimeInterval(config.totalTimeout)
        deadline = until
        backlog = ReplyBacklog(limit: 4)
        let addrs: [String]
        do { addrs = try await HostGuard.resolve(host: config.host, allowedNets: allowedNets) }
        catch HostGuard.Failure.blocked { throw FTPError("target_blocked") } catch { throw FTPError("unresolvable") }
        let pin = PinnedHostKey(expected: config.hostKeySHA256)
        let auth = PasswordAuth(user: config.username, password: config.password)
        let ch: Channel
        do {
            ch = try await ClientBootstrap(group: group).connectTimeout(.seconds(10)).channelInitializer { ch in
                ch.pipeline.addHandler(NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: pin)), allocator: ch.allocator, inboundChildChannelInitializer: nil))
            }.connect(host: addrs[0], port: config.port).get()
        } catch { throw FTPError("connect_failed") }
        root = ch
        var cont: AsyncStream<Result<Data, FTPError>>.Continuation!
        let stream = AsyncStream<Result<Data, FTPError>>(bufferingPolicy: .unbounded) { cont = $0 }   // bounded by ReplyBacklog
        let c = cont!, bl = backlog
        // A refused host key, an exhausted login or a handshake that does not finish in time must end the attempt now,
        // not after the SSH layer's own two-minute timeout.
        let handshakeUntil = min(until, Date().addingTimeInterval(config.timeout))
        let watchdog = Task { [pin, auth, ch] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if pin.rejected || auth.gaveUp || Date() >= handshakeUntil { try? await ch.close(); return }
            }
        }
        defer { watchdog.cancel() }
        let child: Channel
        do {
            child = try await ch.pipeline.handler(type: NIOSSHHandler.self).flatMap { ssh -> EventLoopFuture<Channel> in
                let p = ch.eventLoop.makePromise(of: Channel.self)
                ssh.createChannel(p) { childChannel, kind in
                    guard kind == .session else { return childChannel.eventLoop.makeFailedFuture(FTPError("channel_refused")) }
                    return childChannel.pipeline.addHandler(SFTPPacketHandler(c, backlog: bl))
                }
                return p.futureResult
            }.get()
        } catch {
            try? await ch.close()
            throw pin.seen.isEmpty ? FTPError("connect_failed") : (pin.rejected ? FTPError("host_key_mismatch") : (auth.gaveUp ? FTPError("auth_failed") : FTPError("connect_failed")))
        }
        session = child
        packets = stream.makeAsyncIterator()
        do {
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.SubsystemRequest(subsystem: "sftp", wantReply: true)).get()
        } catch { await close(); throw FTPError("sftp_unavailable") }
        // INIT / VERSION
        try await send(Data([1, 0, 0, 0, 3]))
        let v = try await receive()
        guard v.first == 2 else { await close(); throw FTPError("bad_reply") }
    }

    public func close() async {
        try? await session?.close(); try? await root?.close()
        session = nil; root = nil
    }

    // MARK: packets

    /// Remaining time for one step: at most `timeout`, never beyond the session deadline. `session` tells which one binds.
    private func stepBudget() throws -> (seconds: TimeInterval, session: Bool) {
        if let deadline, deadline < Date().addingTimeInterval(timeout) {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw FTPError("deadline_exceeded") }
            return (left, true)
        }
        return (timeout, false)
    }

    /// A write into an exhausted SSH window never completes: the same timer as for answers closes the channel (gegenlesen Astra 2, Codex 1).
    func send(_ body: Data) async throws {
        guard let s = session else { throw FTPError("not_connected") }
        let (seconds, bySession) = try stepBudget()
        var buf = s.allocator.buffer(capacity: body.count + 4)
        buf.writeInteger(UInt32(body.count)); buf.writeBytes(body)
        let flag = Flag()
        let t = s.eventLoop.scheduleTask(in: .milliseconds(max(1, Int64(seconds * 1000)))) { flag.set(); s.close(promise: nil) }
        defer { t.cancel() }
        do { try await s.writeAndFlush(buf).get() } catch { throw FTPError(flag.value ? (bySession ? "deadline_exceeded" : "timeout") : "connection_closed") }
    }

    private func receive() async throws -> Data {
        guard var it = packets, let s = session else { throw FTPError("not_connected") }
        guard !backlog.overflowed else { throw FTPError("reply_overflow") }
        let (seconds, session) = try stepBudget()
        let flag = Flag()
        let t = s.eventLoop.scheduleTask(in: .milliseconds(max(1, Int64(seconds * 1000)))) { flag.set(); s.close(promise: nil) }
        defer { t.cancel() }
        let next = await it.next()
        packets = it
        guard let n = next else { throw FTPError(flag.value ? (session ? "deadline_exceeded" : "timeout") : "connection_closed") }
        switch n { case .success(let d): backlog.consumed(); return d; case .failure(let e): throw e }
    }
    private final class Flag: @unchecked Sendable { private var v = false; private let l = NSLock(); func set() { l.lock(); v = true; l.unlock() }; var value: Bool { l.lock(); defer { l.unlock() }; return v } }

    private struct W {
        var d = Data()
        mutating func u8(_ v: UInt8) { d.append(v) }
        mutating func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
        mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
        mutating func str(_ s: String) { let b = Array(s.utf8); u32(UInt32(b.count)); d.append(contentsOf: b) }
        mutating func bytes(_ b: Data) { u32(UInt32(b.count)); d.append(b) }
    }
    private struct R {
        let d: Data; var i = 0
        init(_ d: Data) { self.d = Data(d) }
        mutating func u8() throws -> UInt8 { guard i < d.count else { throw FTPError("bad_reply") }; defer { i += 1 }; return d[i] }
        mutating func u32() throws -> UInt32 { guard i + 4 <= d.count else { throw FTPError("bad_reply") }; defer { i += 4 }; return d[i..<i+4].reduce(0) { ($0 << 8) | UInt32($1) } }
        mutating func u64() throws -> UInt64 { let h = try u32(), l = try u32(); return UInt64(h) << 32 | UInt64(l) }
        mutating func bytes() throws -> Data { let n = Int(try u32()); guard n >= 0, i + n <= d.count else { throw FTPError("bad_reply") }; defer { i += n }; return d.subdata(in: i..<i+n) }
        mutating func str() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
        mutating func attrs() throws -> (size: UInt64?, perms: UInt32?) {
            let flags = try u32(); var size: UInt64?, perms: UInt32?
            if flags & 1 != 0 { size = try u64() }
            if flags & 2 != 0 { _ = try u32(); _ = try u32() }
            if flags & 4 != 0 { perms = try u32() }
            if flags & 8 != 0 { _ = try u32(); _ = try u32() }
            if flags & 0x8000_0000 != 0 { let n = try u32(); guard n < 64 else { throw FTPError("bad_reply") }; for _ in 0..<n { _ = try bytes(); _ = try bytes() } }
            return (size, perms)
        }
    }

    /// One request, one matching answer.
    private func request(_ type: UInt8, _ build: (inout W) -> Void) async throws -> (type: UInt8, body: R) {
        if let deadline, deadline <= Date() { throw FTPError("deadline_exceeded") }
        let id = nextID; nextID &+= 1
        var w = W(); w.u8(type); w.u32(id); build(&w)
        try await send(w.d)
        let reply = try await receive()
        var r = R(reply)
        let t = try r.u8(); let rid = try r.u32()
        guard rid == id else { throw FTPError("bad_reply") }
        return (t, r)
    }

    private func status(_ t: UInt8, _ r: R, ok: Set<UInt32> = [0], phase: String) throws {
        guard t == 101 else { throw FTPError("bad_reply") }
        var r = r; let code = try r.u32()
        guard ok.contains(code) else { throw FTPError("sftp_\(code)_\(phase)") }
    }

    private func handle(_ path: String, flags: UInt32) async throws -> Data {
        let (t, r) = try await request(3) { $0.str(path); $0.u32(flags); $0.u32(0) }
        var rr = r
        if t == 101 { try status(t, r, phase: "open"); throw FTPError("bad_reply") }
        guard t == 102 else { throw FTPError("bad_reply") }
        return try rr.bytes()
    }
    private func closeHandle(_ h: Data) async { _ = try? await request(4) { $0.bytes(h) } }

    // MARK: RemoteFileClient

    private func stat(_ path: String, link: Bool = false) async -> (size: UInt64?, perms: UInt32?)? {
        guard let (t, r) = try? await request(link ? 7 : 17, { $0.str(path) }), t == 105 else { return nil }
        var rr = r
        return try? rr.attrs()
    }
    public func exists(_ path: String) async -> Bool { await stat(path) != nil }
    /// LSTAT: a symlink is not a directory here, so recursive removal never leaves the tree it was asked to remove.
    public func isDirectory(_ path: String) async -> Bool { ((await stat(path, link: true))?.perms ?? 0) & 0o170000 == 0o040000 }

    public func makeDirectory(_ path: String) async throws {
        let (t, r) = try await request(14) { $0.str(path); $0.u32(0) }
        do { try status(t, r, phase: "mkdir") } catch let e as FTPError where e.code.hasPrefix("sftp_4") || e.code.hasPrefix("sftp_11") { /* exists: the next step fails visibly if it matters */ }
    }

    public func upload(_ path: String, _ data: Data) async throws {
        let h = try await handle(path, flags: 0x02 | 0x08 | 0x10)   // WRITE|CREAT|TRUNC
        var off = 0
        do {
            repeat {
                let n = min(32 * 1024, data.count - off)
                let chunk = data.subdata(in: off..<off + n)
                let (t, r) = try await request(6) { $0.bytes(h); $0.u64(UInt64(off)); $0.bytes(chunk) }
                try status(t, r, phase: "write")
                off += n
            } while off < data.count
        } catch { await closeHandle(h); throw error }
        let (t, r) = try await request(4) { $0.bytes(h) }
        try status(t, r, phase: "close")
    }

    public func download(_ path: String, limit: Int) async throws -> Data {
        let h = try await handle(path, flags: 0x01)
        var out = Data()
        do {
            while true {
                let (t, r) = try await request(5) { $0.bytes(h); $0.u64(UInt64(out.count)); $0.u32(32 * 1024) }
                if t == 101 { try status(t, r, ok: [1], phase: "read"); break }   // EOF
                guard t == 103 else { throw FTPError("bad_reply") }
                var rr = r; let chunk = try rr.bytes()
                guard !chunk.isEmpty else { throw FTPError("no_progress") }   // an empty DATA packet would repeat the same READ forever (M6)
                out.append(chunk)
                if out.count > limit { throw FTPError("too_large") }
            }
        } catch { await closeHandle(h); throw error }
        await closeHandle(h)
        return out
    }

    public func rename(_ from: String, _ to: String) async throws {
        let (t, r) = try await request(18) { $0.str(from); $0.str(to) }
        try status(t, r, phase: "rename")
    }
    public func delete(_ path: String) async throws { let (t, r) = try await request(13) { $0.str(path) }; try status(t, r, phase: "remove") }
    public func removeDirectory(_ path: String) async throws { let (t, r) = try await request(15) { $0.str(path) }; try status(t, r, phase: "rmdir") }

    public func list(_ dir: String) async throws -> [String] {
        let (t, r) = try await request(11) { $0.str(dir) }
        var rr = r
        if t == 101 { try status(t, r, phase: "opendir"); throw FTPError("bad_reply") }
        guard t == 102 else { throw FTPError("bad_reply") }
        let h = try await rr.bytes()
        var names: [String] = []
        var empty = 0
        do {
            while true {
                let (t2, r2) = try await request(12) { $0.bytes(h) }
                if t2 == 101 { try status(t2, r2, ok: [1], phase: "readdir"); break }
                guard t2 == 104 else { throw FTPError("bad_reply") }
                var x = r2; let n = try x.u32()
                guard n < 10_000 else { throw FTPError("bad_reply") }
                empty = n == 0 ? empty + 1 : 0
                guard empty < 3 else { throw FTPError("no_progress") }   // endless empty NAME batches (M6)
                for _ in 0..<n { let name = try x.str(); _ = try x.str(); _ = try x.attrs(); if name != "." && name != ".." { names.append(name) } }
                if names.count > 100_000 { throw FTPError("too_large") }
            }
        } catch { await closeHandle(h); throw error }
        await closeHandle(h)
        return names
    }
}
