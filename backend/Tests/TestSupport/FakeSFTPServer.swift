// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// In-process SSH/SFTP v3 server; synthetic credentials, an ephemeral host key and a bounded in-memory file system.
public final class FakeSFTPServer: @unchecked Sendable {
    public let user = "storage-user", password = "storage-password"
    private let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
    private let lock = NSLock()
    private var storage: [String: Data] = [:]
    private var directories: Set<String> = ["/", "/objects"]
    private var deleteFailure = false
    private var emptyReadReplies = false
    /// READ answers DATA with zero bytes forever (a client must not loop on it, review Astra 2 M6).
    public var emptyReads: Bool { get { lock.lock(); defer { lock.unlock() }; return emptyReadReplies } set { lock.lock(); emptyReadReplies = newValue; lock.unlock() } }
    private var stalled = false
    /// After the next packet the sessions stop reading: the SSH window is never replenished, so a client write eventually blocks.
    public var stallInput: Bool { get { lock.lock(); defer { lock.unlock() }; return stalled } set { lock.lock(); stalled = newValue; lock.unlock() } }
    public var failDelete: Bool { get { lock.lock(); defer { lock.unlock() }; return deleteFailure } set { lock.lock(); deleteFailure = newValue; lock.unlock() } }
    public var files: [String: Data] { lock.lock(); defer { lock.unlock() }; return storage }
    public var fingerprint: String {
        let line = String(openSSHPublicKey: key.publicKey).split(separator: " ")
        return "SHA256:" + Data(SHA256.hash(data: Data(base64Encoded: String(line[1]))!)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    private var listener: Channel?
    private var children: [Channel] = []
    public private(set) var port = 0
    public init() {}
    public func seed(_ path: String, data: Data) { lock.lock(); storage[path] = data; lock.unlock() }
    fileprivate func change<T>(_ action: (inout [String: Data], inout Set<String>) -> T) -> T { lock.lock(); defer { lock.unlock() }; return action(&storage, &directories) }
    public func start() async throws {
        listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).childChannelInitializer { channel in
            self.lock.lock(); self.children.append(channel); self.lock.unlock()
            return channel.pipeline.addHandler(NIOSSHHandler(role: .server(.init(hostKeys: [self.key], userAuthDelegate: Auth(self))), allocator: channel.allocator, inboundChildChannelInitializer: { child, kind in
                guard kind == .session else { return child.eventLoop.makeFailedFuture(FakeError()) }
                return child.pipeline.addHandler(Session(self))
            }))
        }.bind(host: "127.0.0.1", port: 0).get()
        port = listener!.localAddress!.port!
    }
    public func stop() async { let active = channels(); for c in active { try? await c.close() }; try? await listener?.close() }
    private func channels() -> [Channel] { lock.lock(); defer { lock.unlock() }; return children }
    private struct FakeError: Error {}
    private final class Auth: NIOSSHServerUserAuthenticationDelegate {
        let s: FakeSFTPServer
        init(_ s: FakeSFTPServer) { self.s = s }
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .password }
        func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            if case .password(let p) = request.request, request.username == s.user, p.password == s.password { responsePromise.succeed(.success) }
            else { responsePromise.succeed(.failure) }
        }
    }
    private final class Session: ChannelInboundHandler {
        typealias InboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData
        let s: FakeSFTPServer
        var buffer = Data()
        var handles: [Data: String] = [:]
        init(_ s: FakeSFTPServer) { self.s = s }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let e = event as? SSHChannelRequestEvent.SubsystemRequest {
                if e.subsystem == "sftp" { if e.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) } }
                else { context.triggerUserOutboundEvent(ChannelFailureEvent(), promise: nil) }
            } else { context.fireUserInboundEventTriggered(event) }
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let message = unwrapInboundIn(data)
            if s.stallInput { context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in } }   // later reads stop: the SSH window runs dry
            guard case .byteBuffer(var b) = message.data else { return }
            buffer.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
            while buffer.count >= 4 {
                let count = Int(buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard count <= 1 << 20 else { context.close(promise: nil); return }
                guard buffer.count >= count + 4 else { return }
                let packet = Data(buffer.dropFirst(4).prefix(count)); buffer = Data(buffer.dropFirst(count + 4))
                do { try handle(context, packet) } catch { context.close(promise: nil) }
            }
        }
        func send(_ ctx: ChannelHandlerContext, _ data: Data) {
            var b = ctx.channel.allocator.buffer(capacity: data.count + 4); b.writeInteger(UInt32(data.count)); b.writeBytes(data)
            ctx.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(b))), promise: nil)
        }
        func reply(_ ctx: ChannelHandlerContext, type: UInt8, id: UInt32, body: (inout Writer) -> Void = { _ in }) {
            var w = Writer(); w.d.append(type); w.u32(id); body(&w); send(ctx, w.d)
        }
        func status(_ ctx: ChannelHandlerContext, id: UInt32, code: UInt32) { reply(ctx, type: 101, id: id) { $0.u32(code); $0.str(""); $0.str("") } }
        func handle(_ ctx: ChannelHandlerContext, _ data: Data) throws {
            var r = Reader(d: data)
            let type = try r.byte()
            if type == 1 { send(ctx, Data([2,0,0,0,3])); return }
            let id = try r.u32()
            switch type {
            case 3: // OPEN
                let path = try r.str(), flags = try r.u32()
                if flags & 8 != 0 { s.change { files, _ in if files[path] == nil || flags & 16 != 0 { files[path] = Data() } } }
                guard s.files[path] != nil else { status(ctx, id: id, code: 2); return }
                let h = Data(UUID().uuidString.utf8); handles[h] = path
                reply(ctx, type: 102, id: id) { $0.bytes(h) }
            case 4: let h = try r.bytes(); handles[h] = nil; status(ctx, id: id, code: 0)
            case 5: // READ
                let h = try r.bytes(), offset = try r.u64(), count = try r.u32()
                guard let path = handles[h], let d = s.files[path] else { status(ctx, id: id, code: 4); return }
                if s.emptyReads { reply(ctx, type: 103, id: id) { $0.bytes(Data()) }; return }
                guard offset < d.count else { status(ctx, id: id, code: 1); return }
                reply(ctx, type: 103, id: id) { $0.bytes(Data(d.dropFirst(Int(offset)).prefix(Int(count)))) }
            case 6: // WRITE
                let h = try r.bytes(), offset = try r.u64(), d = try r.bytes()
                guard let path = handles[h], offset <= 64 << 20, d.count <= 1 << 20 else { status(ctx, id: id, code: 4); return }
                s.change { files, _ in
                    var target = files[path] ?? Data()
                    if target.count < Int(offset) + d.count { target.append(Data(repeating: 0, count: Int(offset) + d.count - target.count)) }
                    target.replaceSubrange(Int(offset)..<Int(offset) + d.count, with: d); files[path] = target
                }
                status(ctx, id: id, code: 0)
            case 7, 17: // LSTAT/STAT
                let path = try r.str()
                if let d = s.files[path] { reply(ctx, type: 105, id: id) { $0.u32(5); $0.u64(UInt64(d.count)); $0.u32(0o100600) } }
                else if s.change({ _, dirs in dirs.contains(path) }) { reply(ctx, type: 105, id: id) { $0.u32(4); $0.u32(0o040700) } }
                else { status(ctx, id: id, code: 2) }
            case 13:
                let path = try r.str()
                if s.failDelete { status(ctx, id: id, code: 3); return }
                let existed = s.change { files, _ in files.removeValue(forKey: path) != nil }
                status(ctx, id: id, code: existed ? 0 : 2)
            case 14:
                let path = try r.str(); let fresh = s.change { _, dirs in dirs.insert(path).inserted }; status(ctx, id: id, code: fresh ? 0 : 4)
            case 18:
                let from = try r.str(), to = try r.str()
                let ok = s.change { files, _ -> Bool in guard files[to] == nil, let d = files.removeValue(forKey: from) else { return false }; files[to] = d; return true }
                status(ctx, id: id, code: ok ? 0 : 4)
            default: status(ctx, id: id, code: 8)
            }
        }
    }
    private struct Writer {
        var d = Data()
        mutating func u32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
        mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xffffffff)) }
        mutating func str(_ s: String) { bytes(Data(s.utf8)) }
        mutating func bytes(_ b: Data) { u32(UInt32(b.count)); d.append(b) }
    }
    private struct Reader {
        let d: Data; var i = 0
        mutating func byte() throws -> UInt8 { guard i < d.count else { throw FakeError() }; defer { i += 1 }; return d[i] }
        mutating func u32() throws -> UInt32 { guard i + 4 <= d.count else { throw FakeError() }; defer { i += 4 }; return d[i..<i+4].reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func u64() throws -> UInt64 { let high = try u32(), low = try u32(); return UInt64(high) << 32 | UInt64(low) }
        mutating func bytes() throws -> Data { let n = Int(try u32()); guard i + n <= d.count else { throw FakeError() }; defer { i += n }; return Data(d[i..<i+n]) }
        mutating func str() throws -> String { String(decoding: try bytes(), as: UTF8.self) }
    }
}
