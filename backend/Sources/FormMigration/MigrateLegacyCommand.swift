// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Dispatch
import Vapor
import FluentMySQLDriver
import SQLKit
import Fluent
import FormAuth
import FormPersistence

/// Process end requested by the command: the exit code is applied by the caller after the application was shut down.
public struct MigrateLegacyExit: Error { public let code: Int32 }

public struct MigrateLegacyCommand: AsyncCommand {
    public struct Signature: CommandSignature {
        public init() {}
        @Option(name:"plan", help:"JSON-Importplan mit freigegebener Zuordnung") var plan: String?
        @Flag(name:"dry-run", help:"Transaktion vollständig zurückrollen") var dryRun: Bool
        @Option(name:"batch-size", help:"Quellzeilen pro Batch, Standard 100") var batchSize: Int?
        @Option(name:"expect-source-fingerprint", help:"Quellen-Fingerabdruck (Hex) aus dem Prüflauf; weicht die Quelle ab, bricht der Import ohne Schreiben ab") var expectSourceFingerprint: String?
    }
    public var help: String {
        "Importiert einen isolierten Altbestand ohne Aktivierung oder Außenwirkungen. Exit 0 = abgeschlossen ohne offene Prüffälle, 1 = Fehler, 2 = Parameter-/Planfehler, 3 = abgeschlossen mit offenen Prüffällen, 130/143 = durch SIGINT/SIGTERM an einer Objektgrenze gestoppt (erneuter Aufruf setzt fort)."
    }
    public init() {}

    /// Operator text of the quiesce failures (ADR 0043); the machine-readable description is printed as well.
    static func operatorText(_ failure: ImportFailure) -> String? {
        switch failure {
        case .snapshotChanged: return "Für diese Quelle gibt es schon einen Import mit anderem Snapshot. Ein Nachimport (Delta) ist nicht vorgesehen: Ziel aus der Sicherung wiederherstellen und einmalig neu importieren."
        case .sourceChanged: return "Die Altdaten wurden seit dem Prüflauf verändert. Altsystem in Schreibpause versetzen und den Prüflauf wiederholen."
        case .sourceNotQuiesced: return "Das Altsystem wurde während des Imports beschrieben. Ziel aus der Sicherung wiederherstellen, Schreibpause herstellen und neu importieren."
        default: return nil
        }
    }

    /// Exit code of a run that ended normally but left open review cases (the run state is `failed`, see ADR 0014).
    public static let openCasesExitCode: Int32 = 3

    /// Validated parameters. Failures name the parameter, never a value or secret.
    struct Parameters {
        var plan: String, hmac: Data, serverKey: String, host: String, name: String, user: String, password: String
        var port: Int, insecure: Bool, batchSize: Int
        static func read(plan: String?, batchSize: Int?, env: [String:String]) throws -> Parameters {
            guard let plan else { throw CLIInputError.missing("--plan") }
            let batch = batchSize ?? 100
            guard batch > 0, batch <= 10000 else { throw CLIInputError.invalid("--batch-size", "erlaubt 1 bis 10000") }
            func required(_ name: String) throws -> String { guard let v = env[name], !v.isEmpty else { throw CLIInputError.missing(name) }; return v }
            let keyText = try required("FORM_MIGRATION_HMAC_KEY")
            guard let hmac = Data(base64Encoded: keyText), hmac.count == 32 else { throw CLIInputError.invalid("FORM_MIGRATION_HMAC_KEY", "erwartet 32 Byte Base64") }
            let serverKey = try required("FORM_SERVER_KEY_FILE"), host = try required("LEGACY_DB_HOST"), name = try required("LEGACY_DB_NAME")
            let user = try required("LEGACY_DB_USER"), password = try required("LEGACY_DB_PASSWORD")
            // TLS defaults to verified system trust; cleartext requires the existing explicit development flag.
            let insecure = env["LEGACY_DB_TLS"] == "disable"
            guard !insecure || env["FORM_ALLOW_INSECURE_DEV"] == "1" else { throw CLIInputError.invalid("LEGACY_DB_TLS", "disable nur mit FORM_ALLOW_INSECURE_DEV=1") }
            return Parameters(plan: plan, hmac: hmac, serverKey: serverKey, host: host, name: name, user: user, password: password,
                              port: Int(env["LEGACY_DB_PORT"] ?? "3306") ?? 3306, insecure: insecure, batchSize: batch)
        }
    }

    /// 2 = input (parameters, plan), 130 = stopped by a signal, 1 = every other failure.
    public static func exitCode(for error: Error) -> Int32 {
        if error is CLIInputError { return 2 }
        guard let failure = error as? ImportFailure else { return 1 }
        switch failure {
        case .invalidPlan, .invalidPlanField: return 2
        case .interrupted: return 130
        default: return 1
        }
    }

    public func run(using context: CommandContext, signature: Signature) async throws {
        func finish(_ message: String, _ code: Int32) -> MigrateLegacyExit {
            // Only the controlled diagnostic is displayed; never underlying SQL, decoder errors or values.
            context.console.error(message)
            return MigrateLegacyExit(code: code)
        }
        let params: Parameters, plan: ImportPlan
        if let expected = signature.expectSourceFingerprint, expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil {
            throw finish(CLIInputError.invalid("--expect-source-fingerprint", "erwartet 64 Hexzeichen (Kleinbuchstaben)").description, 2)
        }
        do {
            params = try Parameters.read(plan: signature.plan, batchSize: signature.batchSize, env: ProcessInfo.processInfo.environment)
            guard let data = FileManager.default.contents(atPath: params.plan) else { throw CLIInputError.invalid("--plan", "Datei nicht lesbar") }
            plan = try ImportPlan.decode(data)
        } catch { throw finish(String(describing: error), Self.exitCode(for: error)) }
        let app = context.application
        var cfg = MySQLConfiguration(hostname:params.host,port:params.port,username:params.user,password:params.password,database:params.name)
        if params.insecure { cfg.tlsConfiguration = nil }
        let id = DatabaseID(string:"legacy-migration")
        app.databases.use(.mysql(configuration:cfg,maxConnectionsPerEventLoop:1,sqlLogLevel:nil),as:id)
        var source = app.db(id).logger; source.logLevel = .critical
        let src = app.db(id,logger:source) as! SQLDatabase
        var targetLogger = app.db(.mysql).logger; targetLogger.logLevel = .critical
        let target = app.db(.mysql,logger:targetLogger)
        // SIGINT/SIGTERM: stop at the next object boundary (the importer's checkpoint), so the lock is released and the
        // run can be resumed by calling again. The default action would kill the process between two statements.
        let stop = StopRequest()
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            let s = DispatchSource.makeSignalSource(signal: number, queue: .global())
            s.setEventHandler { stop.request(number) }; s.resume(); return s
        }
        defer { signals.forEach { $0.cancel() } }
        do {
            let importer = try LegacyImporter(source:src,target:target as! SQLDatabase,secrets:SecretStore(db:target,keys:FileServerKey(path:params.serverKey)),hmacKey:params.hmac)
            let report = try await importer.run(plan:plan,dryRun:signature.dryRun,batchSize:params.batchSize,expectedSourceFingerprint:signature.expectSourceFingerprint,checkpoint:{ _,_ in try stop.check() })
            context.console.print(try json(report))
            // Rehearsal: the fingerprint to pass to the real run (--expect-source-fingerprint); the legacy system must rest until then.
            if signature.dryRun { context.console.print("source-fingerprint: \(report.sourceFingerprint)") }
            if !signature.dryRun {
                let open = try await importer.openCases(namespace:plan.namespace)
                if open > 0 { throw finish("abgeschlossen mit \(open) offenen Prüffällen (Lauf steht auf failed; Prüffälle in der Umstieg-Ansicht oder in migration_issues ansehen)", Self.openCasesExitCode) }
            }
        } catch let exit as MigrateLegacyExit { throw exit
        } catch let failure as ImportFailure {
            if case .interrupted = failure, stop.signal != 0 {
                throw finish("unterbrochen durch Signal \(stop.signal) an einer Objektgrenze; erneuter Aufruf setzt fort", 128 + stop.signal)
            }
            throw finish(Self.operatorText(failure).map { failure.description + "\n" + $0 } ?? failure.description, Self.exitCode(for: failure))
        } catch let input as CLIInputError { throw finish(input.description, 2)
        } catch { throw finish(ImportFailure.database.description, 1) }
    }
}
