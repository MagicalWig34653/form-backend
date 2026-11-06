// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// In-process FTP/FTPS server for tests: in-memory file system, passive mode, explicit or implicit TLS (synthetic certificate),
/// switches to simulate failures (refused rename, corrupted storage).
public final class FakeFTPServer: @unchecked Sendable {
    public struct Options {
        public var holdDownloadOpen = false            // sends 226 but never closes the data channel
        public var implicitTLS = false
        public var offerTLS = true
        public var user = "ftpuser", password = "ftppass"
        public var failRenameTo: String? = nil          // RNTO to a path ending with this fails (550)
        public var corruptUploadsNamed: String? = nil   // stores different bytes for files with this name
        public var bogusPasvAddress = false             // PASV names a foreign IP (must be ignored)
        public var passiveReply: String? = nil          // answer EPSV/PASV with this (malformed) text after the code
        public init() {}
    }
    public let options: Options
    private let lock = NSLock()
    private var _files: [String: Data] = [:]
    private var _dirs: Set<String> = ["/"]
    private var _log: [String] = []
    public var files: [String: Data] { lock.lock(); defer { lock.unlock() }; return _files }
    public var dirs: Set<String> { lock.lock(); defer { lock.unlock() }; return _dirs }
    public var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    private var channel: Channel?
    private var children: [ObjectIdentifier: Channel] = [:]
    private var stopped = false

    private func track(_ ch: Channel, seconds: Int64 = 120) {
        var close = false
        mutate { me in
            close = me.stopped
            if !close { me.children[ObjectIdentifier(ch)] = ch }
        }
        if close { ch.close(promise: nil); return }
        let deadline = ch.eventLoop.scheduleTask(in: .seconds(seconds)) { ch.close(promise: nil) }
        ch.closeFuture.whenComplete { _ in
            deadline.cancel()
            self.mutate { $0.children[ObjectIdentifier(ch)] = nil }
        }
    }
    public private(set) var port = 0
    public init(_ o: Options = Options()) { options = o }

    public func seedFile(_ path: String, _ data: Data) { mutate { $0._files[path] = data } }
    public func seedDir(_ path: String) { mutate { $0._dirs.insert(path) } }
    fileprivate func mutate(_ f: (FakeFTPServer) -> Void) { lock.lock(); f(self); lock.unlock() }
    fileprivate func record(_ s: String) { mutate { $0._log.append(s) } }

    public func start() async throws {
        let tls = try FakeSMTPServer.tlsContext()
        let opts = options, me = self
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).childChannelInitializer { ch in
            me.track(ch)
            do {
                if opts.implicitTLS { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                try ch.pipeline.syncOperations.addHandler(Control(server: me, tls: tls))
                return ch.eventLoop.makeSucceededFuture(())
            } catch { return ch.eventLoop.makeFailedFuture(error) }
        }.bind(host: "127.0.0.1", port: 0).get()
        port = channel!.localAddress!.port!
    }
    public func stop() async {
        var active: [Channel] = []
        mutate { me in me.stopped = true; active = Array(me.children.values) }
        try? await channel?.close()
        for ch in active { try? await ch.close() }
    }

    private final class Control: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let server: FakeFTPServer, tls: NIOSSLContext
        var buffer: [UInt8] = []
        var authed = false, userOK = false, dataTLS = false, tlsActive: Bool
        var cwd = "/", renameFrom: String?
        var listener: Channel?
        init(server: FakeFTPServer, tls: NIOSSLContext) { self.server = server; self.tls = tls; tlsActive = server.options.implicitTLS }

        func channelActive(context: ChannelHandlerContext) { reply(context, "220 fake ftp") }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data)
            buffer.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
            while let nl = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<nl]); buffer.removeSubrange(...nl)
                if line.last == 0x0D { line.removeLast() }
                handle(context, String(decoding: line, as: UTF8.self))
            }
        }
        func reply(_ ctx: ChannelHandlerContext, _ s: String) { ctx.writeAndFlush(NIOAny(ByteBuffer(string: s + "\r\n")), promise: nil) }

        func abs(_ p: String) -> String {
            var parts = (p.hasPrefix("/") ? [] : cwd.split(separator: "/").map(String.init))
            for c in p.split(separator: "/") { if c == ".." { _ = parts.popLast() } else if c != "." { parts.append(String(c)) } }
            return "/" + parts.joined(separator: "/")
        }

        func handle(_ ctx: ChannelHandlerContext, _ line: String) {
            let sp = line.firstIndex(of: " ")
            let cmd = (sp.map { String(line[..<$0]) } ?? line).uppercased()
            let arg = sp.map { String(line[line.index(after: $0)...]) } ?? ""
            server.record(cmd == "PASS" ? "PASS ***" : line)
            let o = server.options
            switch cmd {
            case "AUTH":
                guard o.offerTLS, arg.uppercased() == "TLS" else { return reply(ctx, "504 no") }
                reply(ctx, "234 go ahead"); tlsActive = true
                _ = ctx.pipeline.addHandler(NIOSSLServerHandler(context: tls), position: .first)
            case "PBSZ": reply(ctx, "200 ok")
            case "PROT": dataTLS = arg.uppercased() == "P"; reply(ctx, dataTLS ? "200 ok" : "200 clear")
            case "USER": userOK = arg == o.user; reply(ctx, "331 password")
            case "PASS": if userOK && arg == o.password { authed = true; reply(ctx, "230 in") } else { reply(ctx, "530 login incorrect") }
            case "TYPE": reply(ctx, "200 binary")
            case "QUIT": reply(ctx, "221 bye"); ctx.close(promise: nil)
            default:
                guard authed else { return reply(ctx, "530 not logged in") }
                file(ctx, cmd, arg)
            }
        }

        func file(_ ctx: ChannelHandlerContext, _ cmd: String, _ arg: String) {
            let s = server
            switch cmd {
            case "PWD": reply(ctx, "257 \"\(cwd)\"")
            case "CWD":
                let p = abs(arg)
                if s.dirs.contains(p) { cwd = p; reply(ctx, "250 ok") } else { reply(ctx, "550 no such directory") }
            case "CDUP": cwd = abs(".."); reply(ctx, "250 ok")
            case "MKD":
                let p = abs(arg)
                if s.dirs.contains(p) || s.files[p] != nil { reply(ctx, "550 exists") }
                else if !s.dirs.contains(abs(p + "/..")) { reply(ctx, "550 no parent") }
                else { s.mutate { $0._dirs.insert(p) }; reply(ctx, "257 \"\(p)\" created") }
            case "RMD":
                let p = abs(arg)
                let busy = s.files.keys.contains { $0.hasPrefix(p + "/") } || s.dirs.contains { $0 != p && $0.hasPrefix(p + "/") }
                if s.dirs.contains(p), !busy { s.mutate { $0._dirs.remove(p) }; reply(ctx, "250 removed") } else { reply(ctx, "550 cannot remove") }
            case "DELE":
                let p = abs(arg)
                if s.files[p] != nil { s.mutate { $0._files[p] = nil }; reply(ctx, "250 deleted") } else { reply(ctx, "550 no such file") }
            case "SIZE":
                if let d = s.files[abs(arg)] { reply(ctx, "213 \(d.count)") } else { reply(ctx, "550 no such file") }
            case "RNFR":
                let p = abs(arg)
                if s.files[p] != nil || s.dirs.contains(p) { renameFrom = p; reply(ctx, "350 ready") } else { reply(ctx, "550 not found") }
            case "RNTO":
                guard let from = renameFrom else { return reply(ctx, "503 RNFR first") }
                renameFrom = nil
                let to = abs(arg)
                if let f = s.options.failRenameTo, to.hasSuffix(f) { return reply(ctx, "550 rename refused") }
                if s.files[to] != nil || s.dirs.contains(to) { return reply(ctx, "550 target exists") }
                s.mutate { me in
                    if let d = me._files[from] { me._files[from] = nil; me._files[to] = d }
                    else {
                        for k in me._files.keys where k.hasPrefix(from + "/") { me._files[to + k.dropFirst(from.count)] = me._files[k]; me._files[k] = nil }
                        for k in me._dirs where k == from || k.hasPrefix(from + "/") { me._dirs.remove(k); me._dirs.insert(to + k.dropFirst(from.count)) }
                    }
                }
                reply(ctx, "250 renamed")
            case "EPSV", "PASV":
                if let bad = s.options.passiveReply { reply(ctx, (cmd == "EPSV" ? "229 " : "227 ") + bad); return }
                openListener(ctx, extended: cmd == "EPSV")
            case "STOR", "RETR", "NLST":
                transfer(ctx, cmd, arg)
            default: reply(ctx, "502 not implemented")
            }
        }

        var dataGeneration = UUID()
        var received = Data()
        func openListener(_ ctx: ChannelHandlerContext, extended: Bool) {
            let tlsOn = dataTLS, tls = self.tls, me = self
            dataReady = nil
            dataGeneration = UUID()
            let generation = dataGeneration
            let boot = ServerBootstrap(group: ctx.eventLoop).childChannelInitializer { ch in
                me.server.track(ch, seconds: 30)
                do {
                    if tlsOn { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
                    try ch.pipeline.syncOperations.addHandler(DataSink(owner: me, generation: generation))
                    return ch.eventLoop.makeSucceededFuture(())
                } catch { return ch.eventLoop.makeFailedFuture(error) }
            }
            listener?.close(promise: nil)
            let bound = boot.bind(host: "127.0.0.1", port: 0)
            bound.whenSuccess { l in
                self.server.track(l, seconds: 30)
                self.listener = l
                let port = l.localAddress!.port!
                if extended { self.reply(ctx, "229 Entering Extended Passive Mode (|||\(port)|)") }
                else {
                    let ip = self.server.options.bogusPasvAddress ? "8,8,8,8" : "127,0,0,1"
                    self.reply(ctx, "227 Entering Passive Mode (\(ip),\(port / 256),\(port % 256))")
                }
            }
            bound.whenFailure { _ in self.reply(ctx, "425 no data connection") }
        }

        var uploadTarget: String?
        var uploadCtx: ChannelHandlerContext?
        var dataReady: Channel?
        var waitingTransfer: (() -> Void)?

        func transfer(_ ctx: ChannelHandlerContext, _ cmd: String, _ arg: String) {
            let s = server
            let path = abs(arg)
            switch cmd {
            case "STOR":
                guard s.dirs.contains(abs(path + "/..")) else { return reply(ctx, "550 no such directory") }
                uploadTarget = path; uploadCtx = ctx; received = Data()
                reply(ctx, "150 send data")
                // completed by DataSink when the client closes the data connection
            case "RETR":
                guard let d = s.files[path] else { return reply(ctx, "550 no such file") }
                reply(ctx, "150 sending"); sendAndClose(d, ctx)
            default:
                let dir = s.dirs.contains(path) ? path : cwd
                let names = (s.files.keys.filter { abs($0 + "/..") == dir } + s.dirs.filter { $0 != dir && abs($0 + "/..") == dir }).map { String($0.split(separator: "/").last ?? "") }.sorted()
                reply(ctx, "150 listing"); sendAndClose(Data((names.joined(separator: "\r\n") + "\r\n").utf8), ctx)
            }
        }

        func sendAndClose(_ d: Data, _ ctx: ChannelHandlerContext) {
            waitingTransfer = nil
            let go: (Channel) -> Void = { ch in
                var b = ch.allocator.buffer(capacity: d.count); b.writeBytes(d)
                ch.writeAndFlush(b).whenComplete { _ in
                    if !self.server.options.holdDownloadOpen { ch.close(promise: nil) }
                }
                self.reply(ctx, "226 done")
            }
            if let ch = dataReady { dataReady = nil; go(ch) } else { waitingTransfer = { if let ch = self.dataReady { self.dataReady = nil; go(ch) } } }
        }

        func dataConnected(_ ch: Channel, generation: UUID) {
            guard generation == dataGeneration else { ch.close(promise: nil); return }
            dataReady = ch; waitingTransfer?(); waitingTransfer = nil
        }
        func dataReceived(_ d: Data, generation: UUID) {
            guard generation == dataGeneration else { return }
            received.append(d)
        }
        func channelInactive(context: ChannelHandlerContext) {
            waitingTransfer = nil
            uploadCtx = nil
            listener?.close(promise: nil)
            dataReady?.close(promise: nil)
        }

        func dataClosed(_ ch: Channel, generation: UUID) {
            guard generation == dataGeneration else { return }
            if dataReady === ch { dataReady = nil }
            guard let target = uploadTarget, let ctx = uploadCtx else { return }
            uploadTarget = nil
            var stored = received
            if let n = server.options.corruptUploadsNamed, target.hasSuffix(n) { stored = Data("tampered".utf8) }
            server.mutate { $0._files[target] = stored }
            ctx.eventLoop.execute { self.reply(ctx, "226 stored") }
        }
    }

    private final class DataSink: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let owner: Control
        let generation: UUID
        init(owner: Control, generation: UUID) { self.owner = owner; self.generation = generation }
        func channelActive(context: ChannelHandlerContext) { owner.dataConnected(context.channel, generation: generation) }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var b = unwrapInboundIn(data); owner.dataReceived(Data(b.readBytes(length: b.readableBytes) ?? []), generation: generation)
        }
        func channelInactive(context: ChannelHandlerContext) { owner.dataClosed(context.channel, generation: generation) }
    }
}
