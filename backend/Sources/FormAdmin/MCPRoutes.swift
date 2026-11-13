// SPDX-License-Identifier: AGPL-3.0-only
import Fluent
import FormAuth
import FormCore
import FormPersistence
import Foundation
import SQLKit
import Vapor

/// Stateless Streamable HTTP profile: JSON responses, no server-initiated messages or SSE/resume.
enum MCPRoutes {
    static let versions = ["2025-06-18", "2025-03-26"]
    static let tools: [(String, String, [String])] = [
        ("formulare_auflisten", "form.read", ["tenantId"]),
        ("konfiguration_lesen", "form.read", ["tenantId", "formId"]),
        ("entwurf_lesen", "form.read", ["tenantId", "formId", "draftId"]),
        ("entwurf_aendern", "draft.write", ["tenantId", "formId", "draftId", "expectedRevision", "document"]),
        ("entwurf_validieren", "form.read", ["tenantId", "formId", "draftId"])
    ]
    static func register(_ app: Application, guardian: AuthGuard, db: Database, adminResponder: (any Responder)? = nil, now: @escaping @Sendable () -> Date) {
        app.get(".well-known", "oauth-protected-resource") { req async throws -> Response in
            try await guardian.budget(req)
            return try response(["resource": guardian.config.issuer + "/mcp/", "authorization_servers": [guardian.config.issuer], "bearer_methods_supported": ["header"], "scopes_supported": TokenIdentity.scopeRights.keys.sorted()])
        }
        let routes = app.grouped("mcp")
        routes.get { req async throws -> Response in
            try origin(req, guardian)
            _ = try await identity(req, guardian, db, now)
            return Response(status: .methodNotAllowed, headers: ["Allow": "POST"])
        }
        routes.on(.POST, body: .collect(maxSize: "64kb")) { req async throws -> Response in
            try origin(req, guardian)
            let token = try await identity(req, guardian, db, now)
            guard req.headers.contentType == .json else { throw Abort(.unsupportedMediaType) }
            let accept = req.headers[.accept].joined(separator: ",")
            guard accept.contains("application/json"), accept.contains("text/event-stream") else { throw Abort(.notAcceptable) }
            let version = req.headers.first(name: "MCP-Protocol-Version") ?? "2025-03-26"
            guard versions.contains(version) else { throw Abort(.badRequest) }
            guard let buffer = req.body.data else { return try error(NSNull(), -32700) }
            let value: JSONValue
            do { value = try JCS.parse(Data(buffer: buffer)) } catch { return try Self.error(NSNull(), -32700) }
            guard depth(value) <= 16 else { return try error(NSNull(), -32600) }
            guard let obj = value.object, obj["jsonrpc"]?.string == "2.0", let method = obj["method"]?.string,
                  Set(obj.keys).isSubset(of: ["jsonrpc", "method", "id", "params"]),
                  obj["id"] == nil || obj["id"]?.string != nil || obj["id"]?.int != nil || obj["id"] == .null,
                  obj["params"] == nil || obj["params"]?.object != nil else { return try error(NSNull(), -32600) }
            let id = obj["id"]?.foundation ?? NSNull()
            // Notifications never execute tools or mutations.
            if obj["id"] == nil { return Response(status: .accepted) }
            let params = obj["params"]?.object ?? [:]
            let perms = PermissionService(sql: db as! SQLDatabase)
            switch method {
            case "initialize":
                guard Set(params.keys).isSubset(of: ["protocolVersion", "capabilities", "clientInfo"]), params["protocolVersion"]?.string != nil,
                      params["capabilities"]?.object != nil, params["clientInfo"]?.object != nil else { return try error(id, -32602) }
                let requested = params["protocolVersion"]!.string!
                return try reply(id, ["protocolVersion": versions.contains(requested) ? requested : versions[0], "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "Formularverwaltung", "version": "0.1.0"]])
            case "ping":
                guard params.isEmpty else { return try error(id, -32602) }
                return try reply(id, [:])
            case "tools/list":
                guard params.isEmpty else { return try error(id, -32602) }
                var list: [[String: Any]] = try await MCPStatistics.tools(token: token, perms: perms)
                for (name, right, keys) in tools where token.permits(right, on: token.boundary.target) {
                    guard try await perms.can(account: token.accountID, right, on: token.boundary.target) else { continue }
                    var properties: [String: Any] = [:]
                    for key in keys { properties[key] = key == "document" ? ["type": "object"] : key == "expectedRevision" ? ["type": "integer", "minimum": 1] : ["type": "string", "format": "uuid"] }
                    list.append(["name": name, "description": name == "entwurf_validieren" ? "Entwurf ohne Außenwirkung validieren" : name,
                        "inputSchema": ["type": "object", "properties": properties, "required": keys, "additionalProperties": false]])
                }
                return try reply(id, ["tools": list])
            case "tools/call":
                if let name = params["name"]?.string, (MCPStatistics.names.contains(name) || name == "statistik_ads") {
                    guard Set(params.keys) == ["name", "arguments"], let args = params["arguments"]?.object else { return try error(id, -32602) }
                    let input: MCPStatistics.Input
                    do { input = try MCPStatistics.Input(args) } catch { return try Self.error(id, -32602) }
                    do {
                        let data = try await MCPStatistics.call(name, input: input, token: token, db: db, now: now())
                        return try reply(id, ["isError": false, "content": [["type": "text", "text": "Statistikauswertung abgeschlossen."]],
                            "structuredContent": data])
                    } catch { return try toolResult(id, error: true, data: nil) }
                }
                guard Set(params.keys) == ["name", "arguments"], let name = params["name"]?.string,
                      let tool = tools.first(where: { $0.0 == name }), let args = params["arguments"]?.object,
                      Set(args.keys) == Set(tool.2) else { return try error(id, -32602) }
                var ids: [String: UUID] = [:]
                for key in tool.2 where key.hasSuffix("Id") {
                    guard let raw = args[key]?.string, let uuid = UUID(uuidString: raw) else { return try error(id, -32602) }
                    ids[key] = uuid
                }
                if name == "entwurf_aendern", (args["document"]?.object == nil || (args["expectedRevision"]?.int ?? 0) < 1) { return try error(id, -32602) }
                let tenant = ids["tenantId"]!, form = ids["formId"]
                let target: PermissionTarget = (form ?? token.boundary.formId).map { .form(customer: tenant, form: $0) } ?? .customer(tenant)
                do {
                    try await token.authorize(perms, tool.1, on: target)
                    var path = "/admin/api/v1/tenants/\(tenant.uuidString.lowercased())/forms"
                    if let form { path += "/\(form.uuidString.lowercased())" }
                    if let draft = ids["draftId"] { path += "/drafts/\(draft.uuidString.lowercased())" }
                    var headers = HTTPHeaders([("Authorization", req.headers.first(name: .authorization)!), ("Content-Type", "application/json")])
                    if name == "entwurf_aendern" { headers.add(name: .ifMatch, value: "\"\(args["expectedRevision"]!.int!)\"") }
                    let child = Request(application: app, method: name == "entwurf_aendern" ? .PATCH : .GET, url: URI(path: path), headers: headers,
                                        collectedBody: args["document"].map { ByteBuffer(data: JCS.canonicalize($0)) }, on: req.eventLoop)
                    // Only server code can populate this storage; HTTP headers cannot bypass authentication.
                    child.storage[ConfigurationIdentity.InternalKey.self] = ConfigurationIdentity(accountID: token.accountID, token: token)
                    let response = try await (adminResponder ?? app.responder).respond(to: child).get()
                    guard response.status.code < 400, let data = response.body.data,
                          let result = try? JCS.parse(data) else { return try toolResult(id, error: true, data: nil) }
                    if name == "entwurf_validieren" {
                        guard let doc = result["document"], let form else { return try toolResult(id, error: true, data: nil) }
                        try DocumentValidator.validate(doc, tenant: tenant, form: form)
                        return try toolResult(id, error: false, data: ["valid": true])
                    }
                    return try toolResult(id, error: false, data: result.foundation)
                } catch { return try toolResult(id, error: true, data: nil) }
            default: return try error(id, -32601)
            }
        }
    }
    static func identity(_ req: Request, _ guardian: AuthGuard, _ db: Database, _ now: @escaping @Sendable () -> Date) async throws -> TokenIdentity {
        guard req.headers.contains(name: .authorization) else {
            try await guardian.budget(req)
            throw TokenService.Invalid(resource: guardian.config.issuer)
        }
        let identity = try await ConfigurationIdentity.require(req, guardian: guardian, db: db, mutation: false, now: now)
        guard let token = identity.token else { throw TokenService.Invalid(resource: guardian.config.issuer) }
        return token
    }
    static func origin(_ req: Request, _ guardian: AuthGuard) throws {
        if let origin = req.headers.first(name: "Origin"), origin != guardian.config.adminOrigin { throw Abort(.forbidden) }
    }
    static func depth(_ v: JSONValue) -> Int { if let o = v.object { return 1 + (o.values.map(depth).max() ?? 0) }; if let a = v.array { return 1 + (a.map(depth).max() ?? 0) }; return 0 }
    static func response(_ object: [String: Any]) throws -> Response {
        let res = Response(status: .ok, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"])
        res.body = .init(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return res
    }
    static func reply(_ id: Any, _ result: [String: Any]) throws -> Response { try response(["jsonrpc": "2.0", "id": id, "result": result]) }
    static func error(_ id: Any, _ code: Int) throws -> Response { try response(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": "Anfrage ungültig oder Methode unbekannt."]]) }
    static func toolResult(_ id: Any, error: Bool, data: Any?) throws -> Response {
        try reply(id, ["isError": error, "content": [["type": "text", "text": error ? "Aktion nicht möglich." : "Aktion ausgeführt."]],
                       "structuredContent": ["contractVersion": "0.1.0", "proposalStatus": "VORGESCHLAGEN", "data": data ?? NSNull()]])
    }
}
