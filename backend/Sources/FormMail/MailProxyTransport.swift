// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import FormCore
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// The legacy mail-proxy protocol (`mail-proxy/index.php`): POST with header `ACODE`, fields base64-encoded
/// (`mailTo`/`mailBcc`/`mailFrom` as base64 of JSON, `mailBody`, `mailSubject`, `mailReplyTo`, attachment fields), success = HTTP 200,
/// `TEST` header = connection test (202). The proxy always renders HTML, so plain text bodies are wrapped to keep their line breaks.
public struct MailProxyTransport: MailTransport {
    public let url: URL
    public let acode: String
    public let allowedNets: [CIDR]
    public let allowInsecure: Bool
    public let timeout: TimeAmount

    public init(url: URL, acode: String, allowedNets: [CIDR] = [], allowInsecure: Bool = false, timeout: TimeAmount = .seconds(14)) {
        self.url = url; self.acode = acode; self.allowedNets = allowedNets; self.allowInsecure = allowInsecure; self.timeout = timeout
    }

    public static func validate(url: URL, allowInsecure: Bool) throws {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && allowInsecure) else { throw MailTransportError("proxy_url_invalid", transient: false) }
    }

    public func verify() async throws { _ = try await post(fields: nil, test: true) }

    public func send(_ message: MailMessage) async throws {
        func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
        func json(_ v: Any) -> String { b64(String(decoding: (try? JSONSerialization.data(withJSONObject: v)) ?? Data("[]".utf8), as: UTF8.self)) }
        let html = message.isHTML ? message.body : "<pre style=\"font-family:inherit;white-space:pre-wrap\">\(MailTemplate.escapeHTML(message.body))</pre>"
        guard Data(html.utf8).count <= MailMessage.maxBytes else { throw MailTransportError("too_large", transient: false) }
        let fields: [(String, String)] = [
            ("mailTo", json(message.to)), ("mailBcc", json(message.bcc)),
            ("mailFrom", json(["address": message.fromAddress, "name": message.fromName ?? ""])),
            ("mailBody", b64(html)), ("mailSubject", b64(message.subject)), ("mailReplyTo", b64(message.replyTo ?? message.fromAddress)),
            ("mailAttachment", ""), ("mailAttachmentName", ""),
        ]
        _ = try await post(fields: fields, test: false)
    }

    private func post(fields: [(String, String)]?, test: Bool) async throws -> Int {
        do { try Self.validate(url: url, allowInsecure: allowInsecure) } catch { throw error }
        let host = url.host!
        let ip: String
        do { ip = try await HostGuard.resolve(host: host, allowedNets: allowedNets)[0] }
        catch HostGuard.Failure.blocked { throw MailTransportError("target_blocked", transient: false) }
        catch { throw MailTransportError("unresolvable", transient: true) }
        var cfg = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: timeout))
        cfg.dnsOverride = [host: ip]    // connect to the address that was checked; certificate and Host stay those of the name
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: cfg)
        defer { Task { try? await client.shutdown() } }
        var req = HTTPClientRequest(url: url.absoluteString)
        req.method = .POST
        req.headers.add(name: "ACODE", value: acode)
        if test { req.headers.add(name: "TEST", value: "1") }
        req.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = (fields ?? []).map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
        req.body = .bytes(ByteBuffer(string: body))
        let status: Int
        do {
            let res = try await client.execute(req, timeout: timeout + .seconds(5))
            status = Int(res.status.code)
            _ = try? await res.body.collect(upTo: 4096)   // drain; the body (PHP error text) is never used or logged
        } catch { throw MailTransportError("proxy_unreachable", transient: true) }
        switch (test, status) {
        case (false, 200), (true, 202), (true, 200): return status
        case (_, 401): throw MailTransportError("proxy_auth_failed", transient: false)
        case (_, 412): throw MailTransportError("proxy_missing_parameters", transient: false)
        case (_, 500...599): throw MailTransportError("proxy_\(status)", transient: true)
        default: throw MailTransportError("proxy_\(status)", transient: false)
        }
    }
}
