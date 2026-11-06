// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// HTTPS receiver with synthetic TLS material. Captures wire requests and scripts status/body for webhook delivery tests.
public final class FakeWebhookServer: @unchecked Sendable {
    public struct Received: Sendable {
        public let uri: String, headers: HTTPHeaders, body: Data
    }
    private let lock = NSLock()
    private var received: [Received] = []
    private var statuses: [Int]
    private let responseBytes: Int
    private var channel: Channel?
    public private(set) var port = 0
    public var requests: [Received] { lock.lock(); defer { lock.unlock() }; return received }
    public init(statuses: [Int] = [200], responseBytes: Int = 0) { self.statuses = statuses; self.responseBytes = responseBytes }
    private func accept(_ request: Received) -> Int {
        lock.lock(); defer { lock.unlock() }
        received.append(request)
        if statuses.count > 1 { return statuses.removeFirst() }
        return statuses.first ?? 200
    }
    public func start() async throws {
        let tls = try FakeSMTPServer.tlsContext()
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).childChannelInitializer { ch in
            do {
                try ch.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                try ch.pipeline.syncOperations.configureHTTPServerPipeline()
                try ch.pipeline.syncOperations.addHandler(Handler(server: self))
                return ch.eventLoop.makeSucceededFuture(())
            } catch { return ch.eventLoop.makeFailedFuture(error) }
        }.bind(host: "127.0.0.1", port: 0).get()
        port = channel!.localAddress!.port!
    }
    public func stop() async { try? await channel?.close() }
    private final class Handler: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        let server: FakeWebhookServer
        var head: HTTPRequestHead?, body = Data()
        init(server: FakeWebhookServer) { self.server = server }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            switch unwrapInboundIn(data) {
            case .head(let head): self.head = head; body = Data()
            case .body(let buffer): body.append(contentsOf: buffer.readableBytesView)
            case .end:
                guard let head else { context.close(promise: nil); return }
                let status = server.accept(Received(uri: head.uri, headers: head.headers, body: body))
                var headers = HTTPHeaders()
                headers.add(name: "Content-Length", value: String(server.responseBytes))
                headers.add(name: "Connection", value: "close")
                if (300..<400).contains(status) { headers.add(name: "Location", value: "https://127.0.0.1:\(server.port)/redirected") }
                context.write(NIOAny(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers))), promise: nil)
                if server.responseBytes > 0 {
                    context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(repeating: 120, count: server.responseBytes)))), promise: nil)
                }
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in context.close(promise: nil) }
            }
        }
        func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    }
}
