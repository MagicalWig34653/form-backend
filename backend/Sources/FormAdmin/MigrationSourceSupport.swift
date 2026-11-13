// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Why a legacy source could not be used. Every case carries a fixed German text and a short code; neither ever contains a
/// host, user name, password or any driver message.
enum SourceFailure: Error, Equatable, PublicProblemError {
    case authentication, unreachable, database, rights, noTLS, notAllowed, certHostname, certUntrusted, certExpired, generic

    var statusCode: UInt { 422 }
    var code: String { "source_failure" }
    /// Job error column (VARCHAR(40)); the PWA maps these to texts.
    var jobCode: String {
        switch self {
        case .authentication: return "source_auth"
        case .unreachable: return "source_unreachable"
        case .database: return "source_database"
        case .rights: return "source_rights"
        case .noTLS: return "source_no_tls"
        case .notAllowed: return "source_not_allowed"
        case .certHostname: return "source_cert_hostname"
        case .certUntrusted: return "source_cert_untrusted"
        case .certExpired: return "source_cert_expired"
        case .generic: return "source_failed"
        }
    }
    var message: String {
        switch self {
        case .authentication: return "Anmeldung an der Quelle abgelehnt: Benutzer oder Passwort prüfen."
        case .unreachable: return "Die Quelle ist nicht erreichbar: Adresse, Port und Netzwerkfreigabe prüfen."
        case .database: return "Die Quelldatenbank existiert nicht oder der Benutzer darf sie nicht lesen."
        case .rights: return "Der Quellbenutzer hat mehr als Leserechte. Erlaubt sind nur SELECT (und SHOW VIEW), kein Schreiben und keine Rollen."
        case .noTLS: return "Die Quelle bietet kein TLS an. Die Verbindung wurde abgebrochen, bevor Zugangsdaten gesendet wurden. TLS an der Quelle aktivieren."
        case .notAllowed: return "Quelladresse nicht freigegeben oder nicht auflösbar: migration.allowedNets (FORM_MIGRATION_ALLOWED_NETS) muss das Netz der Quelle enthalten."
        case .certHostname: return "Das Zertifikat der Quelle passt nicht zum Hostnamen: Die eingetragene Adresse muss dem Namen im Zertifikat entsprechen."
        case .certUntrusted: return "Das Zertifikat der Quelle stammt von einer unbekannten Stelle. Die Zertifizierungsstelle der Quelle muss im Vertrauensspeicher des Servers (Images) liegen; ein eigenes CA-Feld gibt es nicht."
        case .certExpired: return "Das Zertifikat der Quelle ist abgelaufen. Das Zertifikat an der Quelle erneuern."
        case .generic: return "Quelle konnte nicht sicher geprüft werden."
        }
    }

    /// Maps what the driver or the network stack threw to a cause. Unknown errors are `generic`; nothing of the error survives.
    static func classify(_ error: Error) -> SourceFailure {
        if let failure = error as? SourceFailure { return failure }
        if let mysql = error as? MySQLError {
            switch mysql {
            case .secureConnectionRequired: return .noTLS
            case .closed, .protocolError, .unsupportedServer: return .unreachable
            case .server(let packet):
                if packet.errorCode == .ACCESS_DENIED_ERROR { return .authentication }
                if packet.errorCode == .BAD_DB_ERROR || packet.errorCode == .DBACCESS_DENIED_ERROR { return .database }
                return .generic
            default: return .generic
            }
        }
        // Observed type from MySQLKit/the pool (unwrapped): NIOSSLError.handshakeFailed(.sslError([... CERTIFICATE_VERIFY_FAILED])) for an unknown CA
        // as well as an expired certificate (the diagnosis in `withSource` tells them apart); NIOSSLExtraError.failedToValidateHostname for a name mismatch.
        if let extra = error as? NIOSSLExtraError, extra == .failedToValidateHostname { return .certHostname }
        if let ssl = error as? NIOSSLError {
            switch ssl {
            case .unableToValidateCertificate, .noCertificateToValidate: return .certUntrusted
            case .handshakeFailed: return String(describing: ssl).contains("CERTIFICATE_VERIFY_FAILED") ? .certUntrusted : .generic
            default: return .generic
            }
        }
        if error is NIOConnectionError || error is IOError || error is ChannelError || error is NIOConnectionError { return .unreachable }
        let name = String(describing: type(of: error))
        if name.contains("ConnectionPoolTimeout") || name.contains("ConnectTimeout") || name.contains("NIOConnection") { return .unreachable }
        return .generic
    }
}

/// Reads the server greeting of a MySQL/MariaDB server and reports whether it offers TLS (CLIENT_SSL). The first client packet
/// of mysql-nio already carries the user name and the password scramble, and the driver continues in plain text when the server
/// does not offer TLS, so this check has to happen on a separate connection before any credential is sent.
enum SourceTLSProbe {
    /// nil: not a protocol-10 greeting (error packet, other protocol, truncated).
    static func offersTLS(greeting bytes: [UInt8]) -> Bool? {
        guard bytes.count >= 5, bytes[4] == 10 else { return nil }
        // payload: protocol(1) version(NUL-terminated) thread(4) scramble-1(8) filler(1) capabilities-low(2)
        guard let end = bytes[5...].firstIndex(of: 0) else { return nil }
        let flags = end + 1 + 4 + 8 + 1
        guard bytes.count >= flags + 2 else { return nil }
        let low = UInt16(bytes[flags]) | UInt16(bytes[flags + 1]) << 8
        return low & 0x0800 != 0
    }

    /// Connects to the pinned address, reads the greeting and closes without sending anything.
    static func offersTLS(address: String, port: Int, group: EventLoopGroup, timeout: TimeAmount = .seconds(8)) async throws -> Bool {
        let socket = try SocketAddress(ipAddress: address, port: port)
        let promise = group.next().makePromise(of: [UInt8].self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(timeout)
                .channelInitializer { $0.pipeline.addHandler(GreetingReader(promise: promise)) }
                .connect(to: socket).get()
        } catch {
            promise.fail(SourceFailure.unreachable)  // NIO aborts (debug) on a promise that is never completed
            throw SourceFailure.unreachable
        }
        let timer = channel.eventLoop.scheduleTask(in: timeout) { promise.fail(SourceFailure.unreachable) }
        defer { timer.cancel(); channel.close(promise: nil) }
        let greeting = try await promise.futureResult.get()
        guard let offered = offersTLS(greeting: greeting) else { throw SourceFailure.generic }
        return offered
    }

    /// Diagnosis after a failed certificate check: connects to the pinned address again, reads the greeting, sends ONLY the SSLRequest
    /// (capability flags, no user name, no password) and runs the TLS handshake without verification to read the leaf certificate.
    /// Returns its end of validity (epoch seconds); nil when anything about this fails (the caller keeps "unknown CA").
    static func leafNotValidAfter(address: String, port: Int, group: EventLoopGroup, timeout: TimeAmount = .seconds(8)) async -> Int? {
        guard let socket = try? SocketAddress(ipAddress: address, port: port) else { return nil }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = .none
        guard let context = try? NIOSSLContext(configuration: configuration) else { return nil }
        let promise = group.next().makePromise(of: Int?.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(timeout)
                .channelInitializer { $0.pipeline.addHandler(CertificateReader(promise: promise, context: context)) }
                .connect(to: socket).get()
        } catch {
            promise.succeed(nil)
            return nil
        }
        let timer = channel.eventLoop.scheduleTask(in: timeout) { promise.succeed(nil) }
        defer { timer.cancel(); channel.close(promise: nil) }
        return (try? await promise.futureResult.get()) ?? nil
    }

    /// SSLRequest: 4-byte packet header (length 32, sequence 1), capability flags (PROTOCOL_41, SSL, SECURE_CONNECTION), max packet size 0,
    /// character set utf8mb4 (45), 23 filler bytes. Nothing else is ever sent by the diagnosis.
    static let sslRequest: [UInt8] = [32, 0, 0, 1, 0x00, 0x8A, 0, 0, 0, 0, 0, 0, 45] + [UInt8](repeating: 0, count: 23)

    private final class CertificateReader: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<Int?>, context: NIOSSLContext
        var bytes: [UInt8] = [], requested = false
        init(promise: EventLoopPromise<Int?>, context: NIOSSLContext) { self.promise = promise; self.context = context }
        func channelRead(context ctx: ChannelHandlerContext, data: NIOAny) {
            guard !requested else { return }  // after the SSLRequest everything is TLS and handled by the SSL handler in front of us
            var buffer = unwrapInboundIn(data)
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
            guard bytes.count >= 4 else { return }
            let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
            guard bytes.count >= 4 + length, SourceTLSProbe.offersTLS(greeting: bytes) == true else {
                if bytes.count >= 4 + length || bytes.count > 4096 { promise.succeed(nil); ctx.close(promise: nil) }
                return
            }
            requested = true
            let channel = ctx.channel, tls = self.context
            ctx.writeAndFlush(NIOAny(channel.allocator.buffer(bytes: SourceTLSProbe.sslRequest))).whenComplete { [promise] result in
                guard case .success = result else { promise.succeed(nil); return }
                do { try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: tls, serverHostname: nil), position: .first) }
                catch { promise.succeed(nil) }
            }
        }
        func userInboundEventTriggered(context ctx: ChannelHandlerContext, event: Any) {
            guard case TLSUserEvent.handshakeCompleted = event else { return }
            let certificate = try? ctx.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self).peerCertificate
            promise.succeed(certificate.map { Int($0.notValidAfter) })
            ctx.close(promise: nil)
        }
        func channelInactive(context: ChannelHandlerContext) { promise.succeed(nil) }
        func errorCaught(context: ChannelHandlerContext, error: Error) { promise.succeed(nil); context.close(promise: nil) }
    }

    private final class GreetingReader: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        let promise: EventLoopPromise<[UInt8]>
        var bytes: [UInt8] = []
        init(promise: EventLoopPromise<[UInt8]>) { self.promise = promise }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
            guard bytes.count >= 4 else { return }
            let length = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
            if bytes.count >= 4 + length || bytes.count > 4096 { promise.succeed(bytes) }
        }
        func channelInactive(context: ChannelHandlerContext) { promise.fail(SourceFailure.unreachable) }
        func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(SourceFailure.unreachable); context.close(promise: nil) }
    }
}

/// Limits parallel source checks (each opens a connection to a foreign host): one per account and two overall.
actor SourceTestGate {
    private let perAccount: Int, total: Int
    private var running: [UUID: Int] = [:]
    init(perAccount: Int = 1, total: Int = 2) { self.perAccount = perAccount; self.total = total }
    func enter(_ account: UUID) -> Bool {
        guard running.values.reduce(0, +) < total, (running[account] ?? 0) < perAccount else { return false }
        running[account, default: 0] += 1
        return true
    }
    func leave(_ account: UUID) {
        guard let n = running[account] else { return }
        if n <= 1 { running[account] = nil } else { running[account] = n - 1 }
    }
}

struct SourceBusy: PublicProblemError {
    var statusCode: UInt { 429 }
    var code: String { "source_check_busy" }
    var message: String { "Es läuft bereits eine Quellprüfung. Bitte kurz warten und erneut versuchen." }
    var extraHeaders: [(name: String, value: String)] { [("Retry-After", "5")] }
}

/// 409 of a job action with a reason the page can show (stable code, fixed German text; never a value of the source).
struct MigrationActionRefused: PublicProblemError {
    let code: String, message: String
    var statusCode: UInt { 409 }
    var extraHeaders: [(name: String, value: String)] { [] }
    static let rehearseNotAllowed = MigrationActionRefused(code: "rehearse_not_allowed", message: "Ein Prüflauf lässt sich nur aus einem fertigen Prüflauf oder nach „Die Altdaten wurden verändert“ wiederholen.")
    static let importNeedsRehearsal = MigrationActionRefused(code: "import_needs_rehearsal", message: "Der Import setzt einen fertigen Prüflauf voraus.")
    static let notResumable: Set<String> = ["source_changed", "source_not_quiesced", "snapshot_changed"]
    static let resumeNotPossible = MigrationActionRefused(code: "resume_not_possible", message: "Fortsetzen hilft hier nicht: Altdaten oder Snapshot haben sich geändert. Prüflauf wiederholen oder das Ziel aus der Sicherung wiederherstellen.")
    static let fingerprintMissing = MigrationActionRefused(code: "source_fingerprint_missing", message: "Zu diesem Prüflauf fehlt der Quellen-Fingerabdruck. Prüflauf wiederholen.")
}
