// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Vapor
import FluentMySQLDriver
import SQLKit
import Fluent
import FormAuth
import FormPersistence

public struct MigrateLegacyCommand: AsyncCommand {
    public struct Signature: CommandSignature {
        public init() {}
        @Option(name:"plan", help:"JSON-Importplan mit freigegebener Zuordnung") var plan: String?
        @Flag(name:"dry-run", help:"Transaktion vollständig zurückrollen") var dryRun: Bool
        @Option(name:"batch-size", help:"Quellzeilen pro Batch, Standard 100") var batchSize: Int?
    }
    public var help: String { "Importiert einen isolierten Altbestand ohne Aktivierung oder Außenwirkungen." }
    public init() {}
    public func run(using context: CommandContext, signature: Signature) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = signature.plan, let data = FileManager.default.contents(atPath:path),
              let keyText = env["FORM_MIGRATION_HMAC_KEY"], let hmac = Data(base64Encoded:keyText), hmac.count == 32,
              let serverKey = env["FORM_SERVER_KEY_FILE"], let host = env["LEGACY_DB_HOST"], let name = env["LEGACY_DB_NAME"],
              let user = env["LEGACY_DB_USER"], let password = env["LEGACY_DB_PASSWORD"] else { throw ImportFailure.invalidPlan }
        let app = context.application
        // TLS defaults to verified system trust; cleartext requires the existing explicit development flag.
        let insecure = env["LEGACY_DB_TLS"] == "disable"
        guard !insecure || env["FORM_ALLOW_INSECURE_DEV"] == "1" else { throw ImportFailure.invalidPlan }
        var cfg = MySQLConfiguration(hostname:host,port:Int(env["LEGACY_DB_PORT"] ?? "3306") ?? 3306,username:user,password:password,database:name)
        if insecure { cfg.tlsConfiguration = nil }
        let id = DatabaseID(string:"legacy-migration")
        app.databases.use(.mysql(configuration:cfg,maxConnectionsPerEventLoop:1),as:id)
        var source = app.db(id).logger; source.logLevel = .critical
        let src = app.db(id,logger:source) as! SQLDatabase
        var targetLogger = app.db(.mysql).logger; targetLogger.logLevel = .critical
        let target = app.db(.mysql,logger:targetLogger)
        do {
            let plan = try JSONDecoder().decode(ImportPlan.self,from:data)
            let importer = try LegacyImporter(source:src,target:target as! SQLDatabase,secrets:SecretStore(db:target,keys:FileServerKey(path:serverKey)),hmacKey:hmac)
            let report = try await importer.run(plan:plan,dryRun:signature.dryRun,batchSize:signature.batchSize ?? 100)
            context.console.print(try json(report))
        } catch let failure as ImportFailure {
            // Only the controlled diagnostic is displayed; never underlying SQL or decoder errors.
            context.console.print(failure.description)
            throw failure
        } catch { throw ImportFailure.database }
    }
}
