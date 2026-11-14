// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

public struct SMTPConfig: Sendable, Equatable {
    public enum Security: String, Sendable, Equatable { case tls, starttls, plain }
    public var host: String
    public var port: Int
    public var security: Security
    public var username: String?
    public var password: String?
    public var verifyCertificate: Bool
    public var timeout: TimeInterval
    public var clientName: String

    public init(host: String, port: Int, security: Security, username: String? = nil, password: String? = nil, verifyCertificate: Bool = true,
                timeout: TimeInterval = 30, clientName: String = "localhost") {
        self.host = host; self.port = port; self.security = security; self.username = username; self.password = password
        self.verifyCertificate = verifyCertificate; self.timeout = timeout; self.clientName = clientName
    }
}

struct SMTPReply: Sendable { let code: Int; let lines: [String] }

/// Splits the server byte stream into (multi-line) SMTP replies. Bounded: lines <= 1024 bytes, replies <= 100 lines.
final class SMTPReplyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var pending: [UInt8] = []
    private var lines: [String] = []
    private var code = 0
    let continuation: AsyncStream<Result<SMTPReply, MailTransportError>>.Continuation
    init(_ c: AsyncStream<Result<SMTPReply, MailTransportError>>.Continuation) { continuation = c }

    /// STARTTLS barrier (review M2): from the moment the `220` reply to STARTTLS is complete until the TLS handler sits in the pipeline,
    /// ANY further plaintext byte is an injection attempt (the server must wait for our ClientHello) and aborts the session.
    private var armed = false, locked = false
    func arm() { armed = true }
    func release() { armed = false; locked = false }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if locked { fail(context, "starttls_injection"); return }
        var buf = unwrapInboundIn(data)
        pending.append(contentsOf: buf.readBytes(length: buf.readableBytes) ?? [])
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = Array(pending[..<nl]); pending.removeSubrange(...nl)
            if line.last == 0x0D { line.removeLast() }
            guard line.count <= 1024, line.count >= 3, let c = Int(String(decoding: line[0..<3], as: UTF8.self)), (200...599).contains(c) else { fail(context, "bad_reply"); return }
            if lines.isEmpty { code = c } else if c != code { fail(context, "bad_reply"); return }
            let sep: UInt8? = line.count > 3 ? line[3] : nil
            lines.append(line.count > 4 ? String(decoding: line[4...], as: UTF8.self) : "")
            if lines.count > 100 { fail(context, "bad_reply"); return }
            if sep == nil || sep == 0x20 {
                continuation.yield(.success(SMTPReply(code: code, lines: lines))); lines = []; code = 0
                if armed { locked = true; if !pending.isEmpty { fail(context, "starttls_injection") }; return }
            }
            else if sep != 0x2D { fail(context, "bad_reply"); return }
        }
        if pending.count > 1024 { fail(context, "bad_reply") }
    }
    private func fail(_ ctx: ChannelHandlerContext, _ code: String) { continuation.yield(.failure(MailTransportError(code, transient: true))); ctx.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { continuation.finish() }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.yield(.failure(MailTransportError(error is NIOSSLError || error is BoringSSLError ? "tls_failed" : "connection_error", transient: true)))
        context.close(promise: nil)
    }
}

/// SMTP over SMTPS or STARTTLS with AUTH PLAIN/LOGIN. Certificate and host name are verified unless `verifyCertificate` is off.
/// Targets are checked by `HostGuard` first and the connection goes to the checked literal address.
public struct SMTPTransport: MailTransport {
    public let config: SMTPConfig
    public let allowedNets: [CIDR]
    /// Plain (unencrypted) connections and AUTH over them are refused unless this is set (development only).
    public let allowInsecure: Bool
    let group: EventLoopGroup
    /// Test hook: trust anchors instead of the system roots (lets tests exercise real chain and host-name verification with synthetic certificates).
    var trustRoots: [NIOSSLCertificate]? = nil

    public init(config: SMTPConfig, allowedNets: [CIDR] = [], allowInsecure: Bool = false, group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) {
        self.config = config; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.group = group
    }

    public func verify() async throws { try await run(nil) }
    public func send(_ message: MailMessage) async throws { try await run(message) }

    // MARK: session

    private final class Session: @unchecked Sendable {
        let channel: Channel
        var iterator: AsyncStream<Result<SMTPReply, MailTransportError>>.Iterator
        let timeout: TimeInterval
        init(channel: Channel, iterator: AsyncStream<Result<SMTPReply, MailTransportError>>.Iterator, timeout: TimeInterval) { self.channel = channel; self.iterator = iterator; self.timeout = timeout }

        func read(_ phase: String) async throws -> SMTPReply {
            let timedOut = ManagedFlag()
            let t = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) { timedOut.set(); self.channel.close(promise: nil) }
            defer { t.cancel() }
            guard let next = await iterator.next() else { throw MailTransportError(timedOut.value ? "timeout" : "connection_closed", transient: true) }
            switch next { case .success(let r): return r; case .failure(let e): throw e }
        }

        func write(_ s: String) async throws {
            do { try await channel.writeAndFlush(ByteBuffer(string: s)).get() }
            catch { throw MailTransportError(error is NIOSSLError || error is BoringSSLError ? "tls_failed" : "connection_closed", transient: true) }
        }

        func write(_ d: Data) async throws {
            do { try await channel.writeAndFlush(ByteBuffer(data: d)).get() }
            catch { throw MailTransportError(error is NIOSSLError || error is BoringSSLError ? "tls_failed" : "connection_closed", transient: true) }
        }

        func expect(_ phase: String, _ ok: Set<Int>) async throws -> SMTPReply {
            let r = try await read(phase)
            guard ok.contains(r.code) else { throw MailTransportError("smtp_\(r.code)_\(phase)", transient: r.code / 100 == 4) }
            return r
        }
        func command(_ line: String, _ phase: String, _ ok: Set<Int>) async throws -> SMTPReply { try await write(line + "\r\n"); return try await expect(phase, ok) }
    }
    private final class ManagedFlag: @unchecked Sendable { private var v = false; private let l = NSLock(); func set() { l.lock(); v = true; l.unlock() }; var value: Bool { l.lock(); defer { l.unlock() }; return v } }

    private func tlsContext() throws -> NIOSSLContext {
        var c = TLSConfiguration.makeClientConfiguration()
        // `verifyCertificate:false` is an explicit per-connection choice (decision 0044) and works in production; the channel stays encrypted
        // (`.plain` is refused in `run`, STARTTLS is mandatory and never falls back to clear text).
        if !config.verifyCertificate { c.certificateVerification = .none }
        // Otherwise `.fullVerification` stays: chain and host name are checked. For IP literals no server name is passed (NIOSSL refuses
        // IPs as SNI); NIOSSL then matches the connected address against the certificate's IP SANs only, never the CN.
        if let roots = trustRoots { c.trustRoots = .certificates(roots) }
        return try NIOSSLContext(configuration: c)
    }

    private func run(_ message: MailMessage?) async throws {
        if config.security == .plain && !allowInsecure { throw MailTransportError("insecure_not_allowed", transient: false) }
        let wire = try message.map { try $0.rfc822() }
        let addresses: [String]
        do { addresses = try await HostGuard.resolve(host: config.host, allowedNets: allowedNets) }
        catch HostGuard.Failure.blocked { throw MailTransportError("target_blocked", transient: false) }
        catch { throw MailTransportError("unresolvable", transient: true) }
        let context: NIOSSLContext
        do { context = try tlsContext() } catch let e as MailTransportError { throw e } catch { throw MailTransportError("tls_failed", transient: false) }
        let hostname = IPAddr(config.host) == nil ? config.host : nil
        var stream: AsyncStream<Result<SMTPReply, MailTransportError>>.Continuation!
        let replies = AsyncStream<Result<SMTPReply, MailTransportError>>(bufferingPolicy: .unbounded) { stream = $0 }
        let cont = stream!
        let security = config.security
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(10))
                .channelInitializer { ch in
                    do {
                        if security == .tls { try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: hostname)) }
                        try ch.pipeline.syncOperations.addHandler(SMTPReplyHandler(cont))
                        return ch.eventLoop.makeSucceededFuture(())
                    } catch { return ch.eventLoop.makeFailedFuture(error) }
                }
                .connect(host: addresses[0], port: config.port).get()
        } catch { throw MailTransportError("connect_failed", transient: true) }
        let s = Session(channel: channel, iterator: replies.makeAsyncIterator(), timeout: config.timeout)
        do {
            try await converse(s, context: context, hostname: hostname, wire: wire, message: message)
            _ = try? await s.command("QUIT", "quit", [221])
        } catch {
            _ = try? await s.write("QUIT\r\n")
            try? await channel.close()
            throw error as? MailTransportError ?? MailTransportError("internal", transient: true)
        }
        try? await channel.close()
    }

    private func converse(_ s: Session, context: NIOSSLContext, hostname: String?, wire: Data?, message: MailMessage?) async throws {
        // While a TLS handshake is in progress a dropped connection means the handshake failed (which of read/write sees it first is a race).
        func duringHandshake<T>(_ f: () async throws -> T) async throws -> T {
            do { return try await f() }
            catch let e as MailTransportError where ["connection_closed", "connection_error", "tls_failed"].contains(e.code) { throw MailTransportError("tls_failed", transient: true) }
        }
        if config.security == .tls { _ = try await duringHandshake { try await s.expect("greeting", [220]) } } else { _ = try await s.expect("greeting", [220]) }
        var ehlo = try await s.command("EHLO \(config.clientName)", "ehlo", [250])
        if config.security == .starttls {
            guard ehlo.lines.contains(where: { $0.uppercased() == "STARTTLS" }) else { throw MailTransportError("starttls_unsupported", transient: false) }
            let barrier = try await s.channel.pipeline.handler(type: SMTPReplyHandler.self).get()
            try await s.channel.eventLoop.submit { barrier.arm() }.get()
            _ = try await s.command("STARTTLS", "starttls", [220])
            do { try await s.channel.pipeline.addHandler(NIOSSLClientHandler(context: context, serverHostname: hostname), position: .first).get() }
            catch { throw MailTransportError("tls_failed", transient: true) }
            try await s.channel.eventLoop.submit { barrier.release() }.get()
            ehlo = try await duringHandshake { try await s.command("EHLO \(config.clientName)", "ehlo_tls", [250]) }   // capabilities must be re-read after the upgrade
        }
        if let user = config.username, let pass = config.password {
            guard config.security != .plain || allowInsecure else { throw MailTransportError("auth_over_plain", transient: false) }
            let mechs = ehlo.lines.first(where: { $0.uppercased().hasPrefix("AUTH ") }).map { Set($0.dropFirst(5).uppercased().split(separator: " ").map(String.init)) } ?? []
            if mechs.contains("PLAIN") {
                let cred = Data(([0] + Array(user.utf8) + [0] + Array(pass.utf8))).base64EncodedString()
                do { _ = try await s.command("AUTH PLAIN \(cred)", "auth", [235]) } catch let e as MailTransportError where e.code.hasPrefix("smtp_5") || e.code.hasPrefix("smtp_4") { throw MailTransportError("auth_failed", transient: false) }
            } else if mechs.contains("LOGIN") {
                do {
                    _ = try await s.command("AUTH LOGIN", "auth", [334])
                    _ = try await s.command(Data(user.utf8).base64EncodedString(), "auth", [334])
                    _ = try await s.command(Data(pass.utf8).base64EncodedString(), "auth", [235])
                } catch let e as MailTransportError where e.code.hasPrefix("smtp_") { throw MailTransportError("auth_failed", transient: false) }
            } else { throw MailTransportError("auth_unsupported", transient: false) }
        }
        guard let message, let wire else { return }
        _ = try await s.command("MAIL FROM:<\(message.fromAddress)>", "mail_from", [250])
        for r in message.envelopeRecipients {
            do { _ = try await s.command("RCPT TO:<\(r)>", "rcpt", [250, 251]) }
            catch let e as MailTransportError where e.code.hasPrefix("smtp_") { _ = try? await s.command("RSET", "rset", [250]); throw MailTransportError("rcpt_rejected", transient: e.transient) }
        }
        _ = try await s.command("DATA", "data", [354])
        try await s.write(Self.dotStuffedData(wire))
        _ = try await s.expect("data_end", [250])
    }

    /// Dot-stuffing and the terminating `.` line (RFC 5321 §4.5.2). The message is built with CRLF line ends.
    static func dotStuffed(_ wire: Data) -> String { String(decoding: dotStuffedData(wire), as: UTF8.self) }

    /// Same as `dotStuffed`, as bytes: one output buffer, no String round trip (a mail with a 20 MB attachment is ~27 MB on the wire).
    static func dotStuffedData(_ wire: Data) -> Data {
        var out = Data(); out.reserveCapacity(wire.count + 16)
        var atLineStart = true
        var start = wire.startIndex
        for i in wire.indices {
            let b = wire[i]
            if atLineStart && b == 0x2E { out.append(wire[start..<i]); out.append(0x2E); start = i }
            atLineStart = (b == 0x0A)
        }
        out.append(wire[start..<wire.endIndex])
        if !(out.count >= 2 && out[out.count - 2] == 0x0D && out[out.count - 1] == 0x0A) { out.append(contentsOf: [0x0D, 0x0A]) }
        out.append(contentsOf: Array(".\r\n".utf8))
        return out
    }
}
