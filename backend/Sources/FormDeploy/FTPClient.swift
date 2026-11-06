// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore
import FormMail
import NIOCore
import NIOPosix
import NIOSSL

public struct FTPConfig: Sendable, Equatable {
    public enum Security: String, Sendable, Equatable { case explicitTLS = "explicit-tls", implicitTLS = "implicit-tls", plain }
    public var host: String
    public var port: Int
    public var security: Security
    public var username: String
    public var password: String
    public var verifyCertificate: Bool
    public var timeout: TimeInterval
    public init(host: String, port: Int, security: Security, username: String, password: String, verifyCertificate: Bool = true, timeout: TimeInterval = 30) {
        self.host = host; self.port = port; self.security = security; self.username = username; self.password = password
        self.verifyCertificate = verifyCertificate; self.timeout = timeout
    }
}

public struct FTPError: Error, Equatable, CustomStringConvertible {
    public let code: String
    public init(_ code: String) { self.code = code }
    public var description: String { code }
}

struct FTPReply: Sendable { let code: Int; let text: String }

/// Control-channel reader: complete (possibly multi-line) replies, bounded.
final class FTPReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var pending: [UInt8] = []
    private var lines: [String] = []
    private var first = 0
    let continuation: AsyncStream<Result<FTPReply, FTPError>>.Continuation
    init(_ c: AsyncStream<Result<FTPReply, FTPError>>.Continuation) { continuation = c }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        pending.append(contentsOf: buf.readBytes(length: buf.readableBytes) ?? [])
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = Array(pending[..<nl]); pending.removeSubrange(...nl)
            if line.last == 0x0D { line.removeLast() }
            let text = String(decoding: line, as: UTF8.self)
            guard line.count <= 2048, line.count >= 3, let c = Int(text.prefix(3)), (100...599).contains(c) else { fail(context); return }
            if lines.isEmpty { first = c; lines.append(text) }
            else { lines.append(text) }
            let sep: Character? = text.count > 3 ? text[text.index(text.startIndex, offsetBy: 3)] : nil
            if lines.count > 200 { fail(context); return }
            if lines.count == 1 && sep == "-" { continue }
            if lines.count > 1 && !(text.hasPrefix("\(first) ")) { continue }   // continuation lines until "<code> "
            continuation.yield(.success(FTPReply(code: first, text: lines.joined(separator: "\n"))))
            lines = []
        }
        if pending.count > 4096 { fail(context) }
    }
    private func fail(_ ctx: ChannelHandlerContext) { continuation.yield(.failure(FTPError("bad_reply"))); ctx.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.failure(FTPError(error is NIOSSLError ? "tls_failed" : "connection_error")))
        context.close(promise: nil)
    }
}

/// Collects a data connection until the peer closes it (download / listing); bounded.
final class FTPDataCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var data = Data()
    private let limit: Int
    private var completed = false
    let promise: EventLoopPromise<Data>
    init(limit: Int, promise: EventLoopPromise<Data>) { self.limit = limit; self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data d: NIOAny) {
        var buf = unwrapInboundIn(d)
        data.append(contentsOf: buf.readBytes(length: buf.readableBytes) ?? [])
        if data.count > limit { finish(.failure(FTPError("too_large"))); context.close(promise: nil) }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !completed else { return }
        completed = true
        promise.completeWith(result)
    }
    func channelInactive(context: ChannelHandlerContext) { finish(.success(data)) }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure((error as? FTPError) ?? FTPError(error is NIOSSLError ? "tls_failed" : "data_error"))); context.close(promise: nil)
    }
}

/// Minimal FTP/FTPS client for deploying files (ADR 0011): TLS on the control AND the data channel, passive mode to the address
/// of the checked control connection only, bounded replies and transfers. One instance = one session, not thread-safe.
public final class FTPClient: @unchecked Sendable {
    let config: FTPConfig
    let allowedNets: [CIDR]
    let allowInsecure: Bool
    let group: EventLoopGroup
    private var channel: Channel?
    private var iterator: AsyncStream<Result<FTPReply, FTPError>>.Iterator?
    private var address = ""
    private var context: NIOSSLContext?
    private var dataTLS = false

    public init(config: FTPConfig, allowedNets: [CIDR] = [], allowInsecure: Bool = false, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.group = group
    }

    private func tlsContext() throws -> NIOSSLContext {
        var c = TLSConfiguration.makeClientConfiguration()
        if !config.verifyCertificate {
            guard allowInsecure else { throw FTPError("insecure_not_allowed") }
            c.certificateVerification = .none
        }
        return try NIOSSLContext(configuration: c)
    }

    // MARK: session

    public func connect() async throws {
        if config.security == .plain && !allowInsecure { throw FTPError("insecure_not_allowed") }
        let addrs: [String]
        do { addrs = try await HostGuard.resolve(host: config.host, allowedNets: allowedNets) }
        catch HostGuard.Failure.blocked { throw FTPError("target_blocked") }
        catch { throw FTPError("unresolvable") }
        address = addrs[0]
        let ctx: NIOSSLContext
        do { ctx = try tlsContext() } catch let e as FTPError { throw e } catch { throw FTPError("tls_failed") }
        context = ctx
        let hostname: String? = IPAddr(config.host) == nil ? config.host : nil
        var cont: AsyncStream<Result<FTPReply, FTPError>>.Continuation!
        let replies = AsyncStream<Result<FTPReply, FTPError>>(bufferingPolicy: .unbounded) { cont = $0 }
        let c = cont!
        let implicit = config.security == .implicitTLS
        do {
            channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(10)).channelInitializer { ch in
                do {
                    if implicit { try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ctx, serverHostname: hostname)) }
                    try ch.pipeline.syncOperations.addHandler(FTPReplyHandler(c))
                    return ch.eventLoop.makeSucceededFuture(())
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }.connect(host: address, port: config.port).get()
        } catch { throw FTPError("connect_failed") }
        iterator = replies.makeAsyncIterator()
        _ = try await expect([220], phase: "greeting")
        if config.security == .explicitTLS {
            _ = try await command("AUTH TLS", [234])
            do { try await channel!.pipeline.addHandler(NIOSSLClientHandler(context: ctx, serverHostname: hostname), position: .first).get() }
            catch { throw FTPError("tls_failed") }
        }
        if config.security != .plain {
            _ = try await command("PBSZ 0", [200])
            _ = try await command("PROT P", [200])
            dataTLS = true
        }
        let user = try await command("USER \(try clean(config.username))", [230, 331])
        if user.code == 331 {
            do { _ = try await command("PASS \(try clean(config.password))", [230], secret: true) }
            catch let e as FTPError where e.code.hasPrefix("ftp_5") { throw FTPError("auth_failed") }
        }
        _ = try await command("TYPE I", [200])
    }

    public func close() async {
        if channel != nil { _ = try? await command("QUIT", [221]) }
        try? await channel?.close()
        channel = nil
    }

    private func clean(_ s: String) throws -> String {
        guard !s.isEmpty, !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { throw FTPError("bad_argument") }
        return s
    }

    private func read(_ phase: String) async throws -> FTPReply {
        guard var it = iterator else { throw FTPError("not_connected") }
        let timedOut = Flag()
        let ch = channel!
        let t = ch.eventLoop.scheduleTask(in: .milliseconds(Int64(config.timeout * 1000))) { timedOut.set(); ch.close(promise: nil) }
        defer { t.cancel() }
        let next = await it.next()
        iterator = it
        guard let n = next else { throw FTPError(timedOut.value ? "timeout" : "connection_closed") }
        switch n { case .success(let r): return r; case .failure(let e): throw e }
    }
    private final class Flag: @unchecked Sendable { private var v = false; private let l = NSLock(); func set() { l.lock(); v = true; l.unlock() }; var value: Bool { l.lock(); defer { l.unlock() }; return v } }

    private func expect(_ ok: Set<Int>, phase: String) async throws -> FTPReply {
        var r = try await read(phase)
        while r.code / 100 == 1, !ok.contains(r.code) { r = try await read(phase) }   // preliminary replies
        guard ok.contains(r.code) else { throw FTPError("ftp_\(r.code)_\(phase)") }
        return r
    }

    @discardableResult
    func command(_ line: String, _ ok: Set<Int>, secret: Bool = false) async throws -> FTPReply {
        guard let ch = channel else { throw FTPError("not_connected") }
        do { try await ch.writeAndFlush(ByteBuffer(string: line + "\r\n")).get() } catch { throw FTPError("connection_closed") }
        return try await expect(ok, phase: String(line.prefix(4)).trimmingCharacters(in: .whitespaces).lowercased())
    }

    // MARK: data channel

    private func openData() async throws -> (port: Int, host: String) {
        if let r = try? await command("EPSV", [229]) {
            // 229 Entering Extended Passive Mode (|||port|)
            if let l = r.text.firstIndex(of: "("), let rr = r.text.lastIndex(of: ")"), l < rr {
                let inner = r.text[r.text.index(after: l)..<rr]
                let parts = inner.split(separator: "|", omittingEmptySubsequences: false)
                if parts.count == 5, let p = Int(parts[3]), (1...65535).contains(p) { return (p, address) }
            }
            throw FTPError("bad_passive_reply")
        }
        let r = try await command("PASV", [227])
        guard let l = r.text.firstIndex(of: "("), let rr = r.text.lastIndex(of: ")"), l < rr else { throw FTPError("bad_passive_reply") }
        let n = r.text[r.text.index(after: l)..<rr].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard n.count == 6, n.allSatisfy({ (0...255).contains($0) }) else { throw FTPError("bad_passive_reply") }
        return (n[4] * 256 + n[5], address)   // the address the server names is ignored on purpose (FTP bounce / SSRF)
    }

    private func dataDeadline(_ ch: Channel) -> Scheduled<Void> {
        ch.eventLoop.scheduleTask(in: .milliseconds(Int64(config.timeout * 1000))) {
            ch.pipeline.fireErrorCaught(FTPError("timeout"))
            ch.close(promise: nil)
        }
    }

    private func dataChannel(_ handler: @escaping @Sendable () -> ChannelHandler) async throws -> Channel {
        let p = try await openData()
        let ctx = context!
        let hostname: String? = IPAddr(config.host) == nil ? config.host : nil
        let tls = dataTLS
        do {
            return try await ClientBootstrap(group: group).connectTimeout(.seconds(10)).channelInitializer { ch in
                do {
                    if tls { try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ctx, serverHostname: hostname)) }
                    try ch.pipeline.syncOperations.addHandler(handler())
                    return ch.eventLoop.makeSucceededFuture(())
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }.connect(host: p.host, port: p.port).get()
        } catch { throw FTPError("data_connect_failed") }
    }

    // MARK: operations

    public func download(_ path: String, limit: Int = 8 << 20) async throws -> Data {
        let promise = group.next().makePromise(of: Data.self)
        let ch: Channel
        do { ch = try await dataChannel { FTPDataCollector(limit: limit, promise: promise) } } catch { promise.fail(error); throw error }   // never leak the promise
        let deadline = dataDeadline(ch)
        defer { deadline.cancel(); ch.close(promise: nil) }
        do { _ = try await command("RETR \(try clean(path))", [226, 250]) } catch { try? await ch.close(); throw error }
        do { return try await promise.futureResult.get() } catch let e as FTPError { throw e } catch { throw FTPError("data_error") }
    }

    public func upload(_ path: String, _ bytes: Data) async throws {
        let ch = try await dataChannel { FTPUploadHandler() }
        let deadline = dataDeadline(ch)
        defer { deadline.cancel(); ch.close(promise: nil) }
        // 150 comes first, the data follows, closing the data channel ends the transfer, then 226
        guard let channel = channel else { throw FTPError("not_connected") }
        try await channel.writeAndFlush(ByteBuffer(string: "STOR \(try clean(path))\r\n")).get()
        let pre = try await read("stor")
        guard pre.code == 150 || pre.code == 125 else { try? await ch.close(); throw FTPError("ftp_\(pre.code)_stor") }
        var buf = ch.allocator.buffer(capacity: bytes.count); buf.writeBytes(bytes)
        do { try await ch.writeAndFlush(buf).get() } catch { throw FTPError("data_error") }
        try? await ch.close()
        _ = try await expect([226, 250], phase: "stor")
    }

    public func size(_ path: String) async throws -> Int {
        let r = try await command("SIZE \(try clean(path))", [213])
        guard let n = Int(r.text.dropFirst(4).trimmingCharacters(in: .whitespaces)) else { throw FTPError("bad_size_reply") }
        return n
    }

    public func list(_ dir: String) async throws -> [String] {
        let promise = group.next().makePromise(of: Data.self)
        let ch: Channel
        do { ch = try await dataChannel { FTPDataCollector(limit: 1 << 20, promise: promise) } } catch { promise.fail(error); throw error }
        let deadline = dataDeadline(ch)
        defer { deadline.cancel(); ch.close(promise: nil) }
        do { _ = try await command("NLST \(try clean(dir))", [226, 250]) } catch { try? await ch.close(); throw error }
        let d = try await promise.futureResult.get()
        // "\r\n" is ONE Character in Swift: split on the bytes
        return d.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }).map { String(decoding: $0, as: UTF8.self).split(separator: "/").last.map(String.init) ?? "" }.filter { !$0.isEmpty }
    }

    public func makeDirectory(_ path: String) async throws {
        do { _ = try await command("MKD \(try clean(path))", [257]) }
        catch let e as FTPError where e.code.hasPrefix("ftp_550") { /* exists (or no permission: the next step fails visibly) */ }
    }
    public func changeDirectory(_ path: String) async throws { _ = try await command("CWD \(try clean(path))", [250]) }
    public func rename(_ from: String, _ to: String) async throws {
        _ = try await command("RNFR \(try clean(from))", [350])
        _ = try await command("RNTO \(try clean(to))", [250])
    }
    public func delete(_ path: String) async throws { _ = try await command("DELE \(try clean(path))", [250]) }
    public func removeDirectory(_ path: String) async throws { _ = try await command("RMD \(try clean(path))", [250]) }
    public func exists(_ path: String) async -> Bool {
        if (try? await command("CWD \(clean(path))", [250])) != nil { _ = try? await command("CDUP", [200, 250]); return true }
        return (try? await size(path)) != nil
    }
}

final class FTPUploadHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
}
