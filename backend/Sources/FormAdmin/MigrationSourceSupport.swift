// SPDX-License-Identifier: AGPL-3.0-only
import FormCore
import Foundation
import MySQLNIO
import NIOCore
import NIOPosix

/// Why a legacy source could not be used. Every case carries a fixed German text and a short code; neither ever contains a
/// host, user name, password or any driver message.
enum SourceFailure: Error, Equatable, PublicProblemError {
    case authentication, unreachable, database, rights, noTLS, notAllowed, generic

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
        } catch { throw SourceFailure.unreachable }
        let timer = channel.eventLoop.scheduleTask(in: timeout) { promise.fail(SourceFailure.unreachable) }
        defer { timer.cancel(); channel.close(promise: nil) }
        let greeting = try await promise.futureResult.get()
        guard let offered = offersTLS(greeting: greeting) else { throw SourceFailure.generic }
        return offered
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
