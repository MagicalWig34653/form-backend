// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor

/// Serves the built PWA (`pwa/dist`) so the image is self-contained. API, health and ready routes are never shadowed;
/// unknown extension-less GET paths fall back to `index.html` (client-side router). Cache rules mirror the service worker:
/// content-hashed `/assets/*` are immutable, everything else must revalidate (`sw.js`, HTML, manifest, theme-init).
public struct StaticSiteMiddleware: AsyncMiddleware {
    let root: URL
    static let apiPrefixes = ["/admin", "/api", "/endpoint", "/health", "/healthz", "/.well-known", "/ready", "/oauth", "/mcp"]
    /// Content-Security-Policy of the app shell: same-origin only. `style-src-attr` allows the inline style attributes
    /// that UI primitives set at runtime; no inline scripts, no framing, no plugins.
    static let csp = "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; "
        + "connect-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

    public init?(publicDirectory: String) {
        let url = URL(fileURLWithPath: publicDirectory, isDirectory: true).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) else { return nil }
        root = url
    }

    public func respond(to req: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard req.method == .GET || req.method == .HEAD else { return try await next.respond(to: req) }
        let path = req.url.path
        if Self.apiPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return try await next.respond(to: req) }
        guard let relative = Self.safeRelativePath(path) else { throw Abort(.badRequest) }
        var file = root.appendingPathComponent(relative)
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir)
        let ext = (relative as NSString).pathExtension
        if !exists || isDir.boolValue {
            // Missing file: a path with an extension is a real 404 (no HTML for a missing script); others are app routes.
            guard ext.isEmpty else { throw Abort(.notFound) }
            file = root.appendingPathComponent("index.html")
        }
        let name = file.lastPathComponent
        let res = try await req.fileio.asyncStreamFile(at: file.path)
        if relative.hasPrefix("assets/") { res.headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=31536000, immutable") }
        else { res.headers.replaceOrAdd(name: .cacheControl, value: "no-cache") }
        res.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        res.headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
        if name == "index.html" || ext == "html" { res.headers.replaceOrAdd(name: "Content-Security-Policy", value: Self.csp) }
        if name == "sw.js" { res.headers.replaceOrAdd(name: "Service-Worker-Allowed", value: "/") }
        return res
    }

    /// Percent-decoded, normalised, no traversal, no NUL, no dotfiles. Empty path means the index.
    static func safeRelativePath(_ urlPath: String) -> String? {
        guard let decoded = urlPath.removingPercentEncoding, !decoded.contains("\0"), !decoded.contains("\\") else { return nil }
        var parts: [String] = []
        for p in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." || p.hasPrefix(".") { return nil }   // also rejects ".." and dotfiles
            parts.append(String(p))
        }
        return parts.joined(separator: "/")
    }
}
