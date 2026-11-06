// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// A scriptable in-process SMTP server for tests (synthetic TLS material from Fixtures/).
public final class FakeSMTPServer: @unchecked Sendable {
    public struct Options {
        public var greeting = "220 fake ESMTP"
        public var greetingDelay: TimeAmount? = nil
        public var startTLS = false
        public var implicitTLS = false
        public var authMechanisms: [String] = []
        public var user = "user", password = "secret"
        public var rejectRecipients: Set<String> = []
        public var rcptReplyCode = 550
        public var dataReply = "250 queued"
        public var dropAfterGreeting = false
        /// Plaintext smuggled in right behind the `220` of STARTTLS (a man-in-the-middle forging the answers of the later TLS session).
        public var injectAfterStartTLS: String? = nil
        public init() {}
    }
    public struct Received { public var from = ""; public var rcpts: [String] = []; public var data = ""; public init() {} }

    public let options: Options
    private let lock = NSLock()
    private var _mails: [Received] = [], _commands: [String] = []
    public var mails: [Received] { lock.lock(); defer { lock.unlock() }; return _mails }
    public var commands: [String] { lock.lock(); defer { lock.unlock() }; return _commands }
    fileprivate func log(_ c: String) { lock.lock(); _commands.append(c); lock.unlock() }
    fileprivate func store(_ m: Received) { lock.lock(); _mails.append(m); lock.unlock() }
    private var channel: Channel?
    public private(set) var port = 0

    public init(_ o: Options = Options()) { options = o }

    public static func tlsContext() throws -> NIOSSLContext {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let cert = try NIOSSLCertificate(file: dir.appendingPathComponent("test-cert.pem").path, format: .pem)
        let key = try NIOSSLPrivateKey(file: dir.appendingPathComponent("test-key.pem").path, format: .pem)
        return try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: [.certificate(cert)], privateKey: .privateKey(key)))
    }

    public func start() async throws {
        let tls = try Self.tlsContext()
        let opts = options, me = self
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { ch in
                do {
                    if opts.implicitTLS { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try ch.pipeline.syncOperations.addHandler(Handler(server: me, tls: tls))
                    return ch.eventLoop.makeSucceededFuture(())
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        port = channel!.localAddress!.port!
    }

    public func stop() async { try? await channel?.close() }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let server: FakeSMTPServer, tls: NIOSSLContext
        var tlsActive = false, buf = [UInt8](), inData = false, current = Received(), authStage = 0, authed = false, authUser = ""
        init(server: FakeSMTPServer, tls: NIOSSLContext) { self.server = server; self.tls = tls; tlsActive = server.options.implicitTLS }
        var o: Options { server.options }

        func channelActive(context: ChannelHandlerContext) {
            if o.dropAfterGreeting { context.close(promise: nil); return }
            if let d = o.greetingDelay { context.eventLoop.scheduleTask(in: d) { self.reply(context, self.o.greeting) }; return }
            reply(context, o.greeting)
        }
        func reply(_ ctx: ChannelHandlerContext, _ s: String) { ctx.writeAndFlush(wrapOutboundOut(ByteBuffer(string: s + "\r\n")), promise: nil) }
        typealias OutboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data); buf += b.readBytes(length: b.readableBytes) ?? []
            while let nl = buf.firstIndex(of: 0x0A) {
                var line = Array(buf[..<nl]); buf.removeSubrange(...nl)
                if line.last == 0x0D { line.removeLast() }
                handle(context, String(decoding: line, as: UTF8.self))
            }
        }

        func handle(_ ctx: ChannelHandlerContext, _ line: String) {
            if inData {
                if line == "." { inData = false; server.store(current); current = Received(); reply(ctx, o.dataReply); return }
                current.data += (line.hasPrefix("..") ? String(line.dropFirst()) : line) + "\r\n"
                return
            }
            if authStage > 0 {
                let decoded = Data(base64Encoded: line).map { String(decoding: $0, as: UTF8.self) } ?? ""
                if authStage == 1 { authUser = decoded; authStage = 2; reply(ctx, "334 UGFzc3dvcmQ6"); return }
                authStage = 0
                if authUser == o.user && decoded == o.password { authed = true; reply(ctx, "235 ok") } else { reply(ctx, "535 bad credentials") }
                return
            }
            server.log(line.hasPrefix("AUTH ") ? "AUTH ..." : line)
            let up = line.uppercased()
            if up.hasPrefix("EHLO") {
                var l = ["250-fake"]
                if o.startTLS && !tlsActive { l.append("250-STARTTLS") }
                if !o.authMechanisms.isEmpty { l.append("250-AUTH \(o.authMechanisms.joined(separator: " "))") }
                l.append("250 8BITMIME"); reply(ctx, l.joined(separator: "\r\n"))
            } else if up == "STARTTLS" {
                reply(ctx, "220 go ahead" + (o.injectAfterStartTLS.map { "\r\n" + $0 } ?? "")); tlsActive = true
                _ = ctx.pipeline.addHandler(NIOSSLServerHandler(context: tls), position: .first)
            } else if up.hasPrefix("AUTH PLAIN ") {
                let parts = (Data(base64Encoded: String(line.dropFirst(11))) ?? Data()).split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
                if parts.count == 3 && parts[1] == o.user && parts[2] == o.password { authed = true; reply(ctx, "235 ok") } else { reply(ctx, "535 bad credentials") }
            } else if up == "AUTH LOGIN" { authStage = 1; reply(ctx, "334 VXNlcm5hbWU6")
            } else if up.hasPrefix("MAIL FROM:") {
                if !o.authMechanisms.isEmpty && !authed { reply(ctx, "530 authentication required"); return }
                current.from = String(line.dropFirst(10)).trimmingCharacters(in: CharacterSet(charactersIn: "<>")); reply(ctx, "250 ok")
            } else if up.hasPrefix("RCPT TO:") {
                let r = String(line.dropFirst(8)).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                if o.rejectRecipients.contains(r) { reply(ctx, "\(o.rcptReplyCode) no such user") } else { current.rcpts.append(r); reply(ctx, "250 ok") }
            } else if up == "DATA" { inData = true; reply(ctx, "354 go")
            } else if up == "RSET" { current = Received(); reply(ctx, "250 ok")
            } else if up == "QUIT" { reply(ctx, "221 bye"); ctx.close(promise: nil)
            } else { reply(ctx, "502 unknown") }
        }
    }
}
