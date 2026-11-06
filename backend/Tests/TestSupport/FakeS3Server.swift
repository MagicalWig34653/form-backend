// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// Small S3-compatible TLS test endpoint. The same dispatcher is available for deterministic transport injection.
public final class FakeS3Server: @unchecked Sendable {
    public struct Reply { public let status: Int; public let headers: [String: String]; public let body: Data }
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var failure: Int? = nil
    private var requests: [(String, String)] = []
    public var failWithStatus: Int? { get { lock.lock(); defer { lock.unlock() }; return failure } set { lock.lock(); failure = newValue; lock.unlock() } }
    public var received: [(String, String)] { lock.lock(); defer { lock.unlock() }; return requests }
    public private(set) var port = 0
    private var channel: Channel?
    public init() {}
    public func seed(_ path: String, data: Data) { lock.lock(); files[path] = data; lock.unlock() }
    public func reply(method: String, path: String, headers: [String: String], body: Data) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append((method, path))
        if let failure { return Reply(status: failure, headers: [:], body: Data()) }
        guard headers["authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true, headers["x-amz-date"] != nil else { return Reply(status: 403, headers: [:], body: Data()) }
        switch method {
        case "PUT": files[path] = body; return Reply(status: 200, headers: [:], body: Data())
        case "GET", "HEAD":
            guard let d = files[path] else { return Reply(status: 404, headers: [:], body: Data()) }
            return Reply(status: 200, headers: ["content-length": String(d.count)], body: method == "HEAD" ? Data() : d)
        case "DELETE": files[path] = nil; return Reply(status: 204, headers: [:], body: Data())
        default: return Reply(status: 405, headers: [:], body: Data())
        }
    }
    public func start() async throws {
        let tls = try FakeSMTPServer.tlsContext()
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).childChannelInitializer { ch in
            do { try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls)) }
            catch { return ch.eventLoop.makeFailedFuture(error) }
            return ch.pipeline.configureHTTPServerPipeline().flatMap { ch.pipeline.addHandler(Handler(self)) }
        }.bind(host: "127.0.0.1", port: 0).get()
        port = channel!.localAddress!.port!
    }
    public func stop() async { try? await channel?.close() }
    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        let server: FakeS3Server
        var head: HTTPRequestHead?, body = Data()
        init(_ server: FakeS3Server) { self.server = server }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let h): head = h; body = Data()
            case .body(var b):
                guard body.count + b.readableBytes <= 64 << 20 else { context.close(promise: nil); return }
                body.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
            case .end:
                guard let h = head else { return }
                var headers: [String: String] = [:]; for pair in h.headers { headers[pair.name.lowercased()] = pair.value }
                let r = server.reply(method: h.method.rawValue, path: h.uri, headers: headers, body: body)
                var out = HTTPHeaders(); for (k,v) in r.headers { out.add(name: k, value: v) }
                if out["content-length"].isEmpty { out.add(name: "content-length", value: String(r.body.count)) }
                context.write(wrapOutboundOut(.head(HTTPResponseHead(version: h.version, status: HTTPResponseStatus(statusCode: r.status), headers: out))), promise: nil)
                if !r.body.isEmpty { context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: r.body)))), promise: nil) }
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
