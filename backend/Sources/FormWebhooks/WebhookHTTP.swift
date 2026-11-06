// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import FormMail
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

/// A checked destination. Connect to `ip`, while retaining `host` for HTTP and certificate verification.
public struct WebhookTarget: Sendable {
    public let host: String, ip: String, path: String
    public let port: Int
    public enum Failure: Error { case invalidURL, timeout, responseTooLarge, disconnected }

    public static func validate(_ url: String, resolver: BoundedDNSResolver = .shared) async throws -> WebhookTarget {
        try await validate(url, allowedNets: [], resolver: resolver)
    }

    static func validate(_ url: String, allowedNets: [CIDR], resolver: BoundedDNSResolver = .shared) async throws -> WebhookTarget {
        guard url.utf8.count <= 2048, !url.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7f }),
              let c = URLComponents(string: url), c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.fragment == nil, let host = c.host, !host.isEmpty, c.port.map({ (1...65535).contains($0) }) ?? true else { throw Failure.invalidURL }
        let cleanHost = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let ips = try await HostGuard.resolve(host: cleanHost, allowedNets: allowedNets, resolver: resolver)
        let path = (c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath) + (c.percentEncodedQuery.map { "?" + $0 } ?? "")
        return WebhookTarget(host: cleanHost, ip: ips[0], path: path, port: c.port ?? 443)
    }
}

/// One connection per request, with no redirect or proxy support. The complete operation (including DNS) has an 8 s deadline.
public struct WebhookHTTP: Sendable {
    private let allowedNets: [CIDR]
    private let allowInsecure: Bool
    public init() { allowedNets = []; allowInsecure = false }
    // Internal seam: tests use synthetic certificates on loopback. The application's public initializer is always strict.
    init(testAllowedNets: [CIDR], testAllowInsecure: Bool) { allowedNets = testAllowedNets; allowInsecure = testAllowInsecure }

    public func send(url: String, body: Data, timestamp: String, signature: String) async throws -> Int {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let state = RequestState(loop: loop)
        let timeout = loop.scheduleTask(in: .seconds(8)) { state.fail(WebhookTarget.Failure.timeout) }
        let nets = allowedNets, insecure = allowInsecure
        // DNS runs outside NIO. A late result cannot start a connection after the deadline.
        Task {
            do {
                let target = try await WebhookTarget.validate(url, allowedNets: nets)
                var config = TLSConfiguration.makeClientConfiguration()
                if insecure { config.certificateVerification = .none }
                let tls = try NIOSSLContext(configuration: config)
                let address = try SocketAddress(ipAddress: target.ip, port: target.port)
                loop.execute {
                    guard !state.done else { return }
                    ClientBootstrap(group: loop).connectTimeout(.seconds(3)).channelInitializer { channel in
                        do {
                            state.channel = channel
                            // NIOSSL fullVerification validates a nil hostname against remoteAddress IP SANs; IP literals cannot appear in SNI.
                            try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: IPAddr(target.host) == nil ? target.host : nil))
                            try channel.pipeline.syncOperations.addHTTPClientHandlers()
                            try channel.pipeline.syncOperations.addHandler(ResponseHandler(state: state))
                            return channel.eventLoop.makeSucceededFuture(())
                        } catch { return channel.eventLoop.makeFailedFuture(error) }
                    }.connect(to: address).whenComplete { result in
                        switch result {
                        case .failure(let error): state.fail(error)
                        case .success(let channel):
                            guard !state.done else { channel.close(promise: nil); return }
                            let bracketedHost = target.host.contains(":") ? "[\(target.host)]" : target.host
                            var headers = HTTPHeaders()
                            headers.add(name: "Host", value: bracketedHost + (target.port == 443 ? "" : ":\(target.port)"))
                            headers.add(name: "Content-Type", value: "application/json")
                            headers.add(name: "Content-Length", value: String(body.count))
                            headers.add(name: "Connection", value: "close")
                            headers.add(name: "X-Kubus-Webhook-Timestamp", value: timestamp)
                            headers.add(name: "X-Kubus-Webhook-Signature", value: signature)
                            channel.write(HTTPClientRequestPart.head(HTTPRequestHead(version: .http1_1, method: .POST, uri: target.path, headers: headers)), promise: nil)
                            channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
                            channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { state.fail($0) }
                        }
                    }
                }
            } catch { loop.execute { state.fail(error) } }
        }
        do {
            let status = try await state.promise.futureResult.get()
            timeout.cancel()
            return status
        } catch {
            timeout.cancel()
            throw error
        }
    }
}

/// Accessed only on its event loop; completing once also cancels the socket on every error path.
private final class RequestState: @unchecked Sendable {
    let promise: EventLoopPromise<Int>
    var done = false
    var channel: Channel?
    init(loop: EventLoop) { promise = loop.makePromise(of: Int.self) }
    func fail(_ error: Error) { guard !done else { return }; done = true; promise.fail(error); channel?.close(promise: nil) }
    func succeed(_ status: Int) { guard !done else { return }; done = true; promise.succeed(status); channel?.close(promise: nil) }
}

private final class ResponseHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    let state: RequestState
    var status: Int?, bytes = 0
    init(state: RequestState) { self.state = state }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            // Informational responses may precede the final response.
            if head.status.code >= 200 { status = Int(head.status.code) }
            if let length = head.headers.first(name: "content-length").flatMap(Int.init), length > 65_536 { state.fail(WebhookTarget.Failure.responseTooLarge) }
        case .body(let body):
            bytes += body.readableBytes
            if bytes > 65_536 { state.fail(WebhookTarget.Failure.responseTooLarge) }
        case .end:
            if let status { state.succeed(status) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { state.fail(error) }
    func channelInactive(context: ChannelHandlerContext) { state.fail(WebhookTarget.Failure.disconnected) }
}
