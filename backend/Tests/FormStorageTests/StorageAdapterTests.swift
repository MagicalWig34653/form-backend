// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import FormCore
import TestSupport
import XCTest
@testable import FormStorage

final class StorageAdapterTests: XCTestCase {
    private let credential = #"{"accessKeyId":"AKIDEXAMPLE","secretAccessKey":"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"}"#
    private let loopback = [CIDR("127.0.0.0/8")!]
    private func config(_ endpoint: String = "https://127.0.0.1") -> [String: Any] { ["endpoint": endpoint, "region": "us-east-1", "bucket": "test-bucket", "pathStyle": true] }
    private func expect(_ code: String, _ action: () async throws -> Void, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected \(code)", line: line) }
        catch let e as StorageError { XCTAssertEqual(e.code, code, line: line) }
        catch { XCTFail("Unexpected \(error)", line: line) }
    }

    func testSigV4FixedVector() throws {
        // AWS example credentials/date, without optional Range; expected signature independently generated with Python hashlib/hmac.
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z"))
        let h = S3Signer.sign(method: "GET", path: "/test.txt", host: "examplebucket.s3.amazonaws.com", region: "us-east-1", accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", payload: Data(), date: date)
        XCTAssertEqual(h["x-amz-content-sha256"], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(h["x-amz-date"], "20130524T000000Z")
        XCTAssertEqual(h["authorization"], "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=df548e2ce037944d03f3e68682813b093763996d597cf890ca3d9037fd231eb4")
        let put = S3Signer.sign(method: "PUT", path: "/test.txt", host: "examplebucket.s3.amazonaws.com", region: "us-east-1", accessKeyId: "AKIAIOSFODNN7EXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", payload: Data("changed".utf8), date: date)
        XCTAssertNotEqual(put["authorization"], h["authorization"])
        let secondDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-03T12:34:56Z"))
        let escaped = S3Signer.sign(method: "PUT", path: "/bucket/a%20b%2Bc%25", host: "s3.example.test:9443", region: "eu-central-1", accessKeyId: "AKID", secretAccessKey: "secret", payload: Data("sealed package".utf8), date: secondDate)
        XCTAssertEqual(escaped["authorization"], "AWS4-HMAC-SHA256 Credential=AKID/20261103/eu-central-1/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=0515ad96a7ee550adef084460e2fd98022fdb747242429891888e4ac994c8774")
    }

    func testS3RoundTripEscapingMissingAndDeletionFailure() async throws {
        let fake = FakeS3Server()
        let s = try S3ObjectStore(config: config(), credential: credential, allowedNets: loopback) { req in
            let r = fake.reply(method: req.method, path: URLComponents(string: req.url)!.percentEncodedPath, headers: req.headers, body: req.body)
            return .init(status: r.status, headers: r.headers, body: r.body)
        }
        let payload = Data((0..<90_000).map { UInt8($0 % 251) })
        let key = "tenant/revision/ä +%.sealed"
        try await s.put(key, data: payload)
        let size = try await s.head(key), back = try await s.get(key)
        XCTAssertEqual(size, payload.count); XCTAssertEqual(back, payload)
        XCTAssertEqual(fake.received.first?.1, "/test-bucket/tenant/revision/%C3%A4%20%2B%25.sealed")
        fake.failWithStatus = 503
        await expect("s3_http_503") { try await s.delete(key) }
        fake.failWithStatus = nil
        let retained = try await s.get(key); XCTAssertEqual(retained, payload)
        try await s.delete(key); try await s.delete(key)
        let absent = try await s.head(key); XCTAssertNil(absent)
        await expect("object_missing") { _ = try await s.get(key) }
        fake.failWithStatus = 307
        await expect("s3_http_307") { _ = try await s.get(key) }
    }

    func testS3VersionMarkersNeverConfirmPhysicalDeletion() async throws {
        let store = try S3ObjectStore(config: config(), credential: credential, allowedNets: loopback) { _ in
            .init(status: 200, headers: ["x-amz-version-id": "marker-version", "x-amz-delete-marker": "true"], body: Data())
        }
        await expect("versioned_bucket_unsupported") { try await store.put("object", data: Data("sealed".utf8)) }
        await expect("versioned_bucket_unsupported") { try await store.delete("object") }
    }

    func testS3TLSConfigurationAndHostGuard() async throws {
        for endpoint in ["http://127.0.0.1", "https://u:p@example.com", "https://example.com/path", "https://example.com?q=x", "https://example.com#frag"] {
            XCTAssertThrowsError(try S3ObjectStore(config: config(endpoint), credential: credential), endpoint)
        }
        let blocked = try S3ObjectStore(config: config(), credential: credential, allowedNets: []) { _ in XCTFail("blocked before transport"); return .init(status: 200, headers: [:], body: Data()) }
        await expect("target_blocked") { _ = try await blocked.head("key") }
    }

    func testS3RejectsUntrustedTLS() async throws {
        let fake = FakeS3Server()
        try await fake.start()
        do {
            let tls = try S3ObjectStore(config: config("https://127.0.0.1:\(fake.port)"), credential: credential, allowedNets: loopback)
            await expect("s3_unreachable") { _ = try await tls.head("key") } // synthetic certificate is deliberately untrusted
        }
        await fake.stop()
    }

    func testObjectKeysRejectTraversalControlAndUnboundedNames() throws {
        for key in ["", "/absolute", "trailing/", "a//b", "a/../b", "./a", "a\\b", "line\nfeed", String(repeating: "a", count: 1025)] {
            XCTAssertThrowsError(try ObjectStoreLimits.validateKey(key), key)
        }
        XCTAssertNoThrow(try ObjectStoreLimits.validateKey("customer/form/object.2.sealed"))
    }

    func testSFTPPinnedRoundTripAndFailedDelete() async throws {
        let fake = FakeSFTPServer()
        try await fake.start()
        do {
            let cfg: [String: Any] = ["host": "127.0.0.1", "port": fake.port, "username": fake.user, "hostKeySha256": fake.fingerprint, "root": "/objects"]
            let s = try SFTPObjectStore(config: cfg, credential: fake.password, allowedNets: loopback)
            let payload = Data((0..<90_000).map { UInt8($0 % 251) })
            try await s.put("customer/form/object.0", data: payload)
            let back = try await s.get("customer/form/object.0"), size = try await s.head("customer/form/object.0")
            XCTAssertEqual(back, payload); XCTAssertEqual(size, payload.count)
            fake.failDelete = true
            do { try await s.delete("customer/form/object.0"); XCTFail("Denied removal must fail") } catch {}
            XCTAssertEqual(fake.files["/objects/customer/form/object.0"], payload)
            fake.failDelete = false
            try await s.delete("customer/form/object.0"); try await s.delete("customer/form/object.0")
            let absent = try await s.head("customer/form/object.0"); XCTAssertNil(absent)
            var bad = cfg; bad["hostKeySha256"] = "SHA256:" + String(repeating: "A", count: 43)
            let wrong = try SFTPObjectStore(config: bad, credential: fake.password, allowedNets: loopback)
            do { _ = try await wrong.head("key"); XCTFail("Mismatched key must fail") } catch {}
            let blocked = try SFTPObjectStore(config: cfg, credential: fake.password)
            do { _ = try await blocked.head("key"); XCTFail("Blocked target must fail") } catch {}
        } catch { await fake.stop(); throw error }
        await fake.stop()
    }
}
