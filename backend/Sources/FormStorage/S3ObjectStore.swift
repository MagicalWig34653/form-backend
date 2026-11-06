// SPDX-License-Identifier: AGPL-3.0-only
import AsyncHTTPClient
import Crypto
import FormCore
import FormMail
import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1

/// AWS Signature Version 4 for S3 single-object requests (no query parameters).
public enum S3Signer {
    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }
    public static func sign(method: String, path: String, host: String, region: String, accessKeyId: String, secretAccessKey: String, payload: Data, date: Date) -> [String: String] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date), day = String(timestamp.prefix(8))
        let hash = hex(Data(SHA256.hash(data: payload)))
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = "\(method)\n\(path)\n\nhost:\(host)\nx-amz-content-sha256:\(hash)\nx-amz-date:\(timestamp)\n\n\(signedHeaders)\n\(hash)"
        let scope = "\(day)/\(region)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(Data(SHA256.hash(data: Data(canonical.utf8)))))"
        let signingKey = hmac(hmac(hmac(hmac(Data(("AWS4" + secretAccessKey).utf8), day), region), "s3"), "aws4_request")
        return ["host": host, "x-amz-content-sha256": hash, "x-amz-date": timestamp,
                "authorization": "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(hex(hmac(signingKey, toSign)))"]
    }
}

public struct S3ObjectStore: ObjectStore {
    struct WireRequest { let url: String; let method: String; let headers: [String: String]; let body: Data }
    struct WireResponse { let status: Int; let headers: [String: String]; let body: Data }
    typealias Transport = @Sendable (WireRequest) async throws -> WireResponse
    private let endpoint: URL
    private let region: String
    private let bucket: String
    private let pathStyle: Bool
    private let accessKeyId: String
    private let secretAccessKey: String
    private let allowedNets: [CIDR]
    private var transport: Transport?

    public init(config: [String: Any], credential: String, allowedNets: [CIDR] = []) throws {
        guard let text = config["endpoint"] as? String, let url = URL(string: text), url.scheme == "https", let host = url.host,
              !host.isEmpty, host.utf8.count <= 253, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", (1...65535).contains(url.port ?? 443),
              let region = config["region"] as? String, region.range(of: "^[a-z0-9-]{1,64}$", options: .regularExpression) != nil,
              let bucket = config["bucket"] as? String, bucket.range(of: "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", options: .regularExpression) != nil,
              !bucket.contains(".."),
              let creds = try? JSONSerialization.jsonObject(with: Data(credential.utf8)) as? [String: String],
              let access = creds["accessKeyId"], access.range(of: "^[A-Za-z0-9]{1,128}$", options: .regularExpression) != nil,
              let secret = creds["secretAccessKey"], !secret.isEmpty, secret.utf8.count <= 128 else { throw StorageError("invalid_s3_config") }
        self.endpoint = url; self.region = region; self.bucket = bucket; self.pathStyle = config["pathStyle"] as? Bool ?? true
        self.accessKeyId = access; self.secretAccessKey = secret; self.allowedNets = allowedNets
    }

    // Test transport keeps endpoint validation, signing and SSRF checks identical to production.
    init(config: [String: Any], credential: String, allowedNets: [CIDR], transport: @escaping Transport) throws {
        try self.init(config: config, credential: credential, allowedNets: allowedNets); self.transport = transport
    }

    private func request(_ method: String, key: String, payload: Data = Data()) async throws -> WireResponse {
        try ObjectStoreLimits.validateKey(key)
        guard payload.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        let rawHost = endpoint.host!
        let host = pathStyle ? rawHost : bucket + "." + rawHost
        let authority = host + (endpoint.port.map { ":\($0)" } ?? "")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        let path = "/" + (pathStyle ? bucket + "/" : "") + key.addingPercentEncoding(withAllowedCharacters: allowed)!
        let headers = S3Signer.sign(method: method, path: path, host: authority, region: region, accessKeyId: accessKeyId, secretAccessKey: secretAccessKey, payload: payload, date: Date())
        let ip: String
        do { ip = try await HostGuard.resolve(host: host, allowedNets: allowedNets)[0] }
        catch HostGuard.Failure.blocked { throw StorageError("target_blocked") }
        catch { throw StorageError("unresolvable") }
        let wire = WireRequest(url: "https://" + authority + path, method: method, headers: headers, body: payload)
        let result: WireResponse
        if let transport { result = try await transport(wire) }
        else {
            var cfg = HTTPClient.Configuration(redirectConfiguration: .disallow, timeout: .init(connect: .seconds(5), read: .seconds(30)))
            cfg.dnsOverride = [host: ip]
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: cfg)
            do {
                var req = HTTPClientRequest(url: wire.url); req.method = HTTPMethod(rawValue: method)
                for (name, value) in headers { req.headers.add(name: name, value: value) }
                if method == "PUT" { req.body = .bytes(ByteBuffer(data: payload)) }
                let response = try await client.execute(req, timeout: .seconds(40))
                var body = try await response.body.collect(upTo: method == "GET" ? ObjectStoreLimits.maxBytes : 4096)
                var responseHeaders: [String: String] = [:]
                for header in response.headers { responseHeaders[header.name.lowercased()] = header.value }
                result = WireResponse(status: Int(response.status.code), headers: responseHeaders, body: Data(body.readBytes(length: body.readableBytes) ?? []))
                try await client.shutdown()
            } catch { try? await client.shutdown(); throw StorageError("s3_unreachable") }
        }
        guard result.body.count <= ObjectStoreLimits.maxBytes else { throw StorageError("too_large") }
        if result.status == 404 { return result }
        guard (200..<300).contains(result.status) else { throw StorageError("s3_http_\(result.status)") }
        return result
    }
    public func put(_ key: String, data: Data) async throws {
        let response = try await request("PUT", key: key, payload: data)
        guard response.status != 404 else { throw StorageError("s3_http_404") }
        if response.headers["x-amz-version-id"] != nil { throw StorageError("versioned_bucket_unsupported") }
    }
    public func get(_ key: String) async throws -> Data {
        let response = try await request("GET", key: key)
        guard response.status != 404 else { throw StorageError("object_missing") }
        return response.body
    }
    public func delete(_ key: String) async throws {
        let response = try await request("DELETE", key: key)
        // A delete marker does not erase older ciphertext versions. Never acknowledge it as physical erasure.
        guard response.headers["x-amz-version-id"] == nil, response.headers["x-amz-delete-marker"] != "true" else { throw StorageError("versioned_bucket_unsupported") }
    }
    public func head(_ key: String) async throws -> Int? {
        let response = try await request("HEAD", key: key)
        if response.status == 404 { return nil }
        guard let text = response.headers["content-length"], let count = Int(text), count >= 0 else { throw StorageError("s3_invalid_length") }
        return count
    }
}
