// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import XCTest
import XCTVapor
@testable import FormHTTP

final class StaticSiteTests: XCTestCase {
    private func site(_ body: (Application, URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("site-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try "<html>app shell</html>".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "console.log(1)".write(to: dir.appendingPathComponent("assets/app-abc.js"), atomically: true, encoding: .utf8)
        try "sw".write(to: dir.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.deletingLastPathComponent().appendingPathComponent("outside-\(dir.lastPathComponent).txt"), atomically: true, encoding: .utf8)
        try ".hidden".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try await Application.make(.testing)
        defer { Task { try? await app.asyncShutdown() } }
        try HTTPSetup.configure(app, publicDirectory: dir.path)
        app.get("admin", "api", "v1", "ping") { _ in "pong" }
        try await body(app, dir)
    }

    func testServesFilesWithCacheRulesAndSecurityHeaders() async throws {
        try await site { app, _ in
            try await app.test(.GET, "assets/app-abc.js") { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: .cacheControl), "public, max-age=31536000, immutable")
                XCTAssertEqual(res.headers.first(name: "X-Content-Type-Options"), "nosniff")
                XCTAssertNil(res.headers.first(name: "Content-Security-Policy"))
            }
            try await app.test(.GET, "sw.js") { res async throws in
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
                XCTAssertEqual(res.headers.first(name: "Service-Worker-Allowed"), "/")
            }
            try await app.test(.GET, "") { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.body.string, "<html>app shell</html>")
                XCTAssertEqual(res.headers.first(name: .cacheControl), "no-cache")
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                for d in ["default-src 'self'", "script-src 'self'", "object-src 'none'", "frame-ancestors 'none'", "base-uri 'none'"] { XCTAssertTrue(csp.contains(d), d) }
                XCTAssertFalse(csp.contains("script-src 'self' 'unsafe"), "no unsafe script sources")
            }
        }
    }

    func testSPAFallbackOnlyForExtensionlessPathsAndNeverForAPI() async throws {
        try await site { app, _ in
            try await app.test(.GET, "login") { XCTAssertEqual($0.body.string, "<html>app shell</html>") }
            try await app.test(.GET, "forms/123/edit") { XCTAssertEqual($0.status, .ok) }
            try await app.test(.GET, "assets/missing.js") { XCTAssertEqual($0.status, .notFound) }       // no HTML for a missing script
            try await app.test(.GET, "nope.css") { XCTAssertEqual($0.status, .notFound) }
            try await app.test(.GET, "admin/api/v1/ping") { XCTAssertEqual($0.body.string, "pong") }      // API wins
            try await app.test(.GET, "admin/api/v1/unknown") { XCTAssertEqual($0.status, .notFound) }     // and its 404 is not the shell
            try await app.test(.POST, "login") { XCTAssertNotEqual($0.body.string, "<html>app shell</html>") }
            try await app.test(.GET, "health") { XCTAssertEqual($0.status, .ok) }
        }
    }

    func testPathTraversalAndDotfilesAreRejected() async throws {
        try await site { app, dir in
            for p in ["..%2F" + "outside-\(dir.lastPathComponent).txt", "%2e%2e/etc/passwd", "assets/%2e%2e/%2e%2e/x", ".env", "assets/.env", "a%00b", "a%5Cb"] {
                try await app.test(.GET, p) { res async throws in
                    XCTAssertTrue([.badRequest, .notFound].contains(res.status), "\(p) -> \(res.status)")
                    XCTAssertFalse((res.body.string).contains("secret") || res.body.string.contains("hidden"), p)
                }
            }
        }
    }

    func testSafeRelativePathAndMissingIndex() {
        XCTAssertEqual(StaticSiteMiddleware.safeRelativePath("/"), "")
        XCTAssertEqual(StaticSiteMiddleware.safeRelativePath("/assets//a.js"), "assets/a.js")
        XCTAssertNil(StaticSiteMiddleware.safeRelativePath("/../x")); XCTAssertNil(StaticSiteMiddleware.safeRelativePath("/.git/config"))
        XCTAssertNil(StaticSiteMiddleware(publicDirectory: "/nonexistent-dir"))
    }
}
