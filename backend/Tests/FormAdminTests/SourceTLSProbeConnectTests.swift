// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import NIOCore
import NIOPosix
import XCTest

/// The probe opens its own connection. When the connect fails, the promise it created must still be completed: NIO aborts
/// the process in debug builds ("leaking promise") otherwise, which crashed the whole test run on Linux.
final class SourceTLSProbeConnectTests: XCTestCase {
    func testUnreachableSourceReportsUnreachableWithoutLeakingThePromise() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        // Find a free port, then close it again so nothing listens there.
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        try await server.close()
        do {
            _ = try await SourceTLSProbe.offersTLS(address: "127.0.0.1", port: port, group: group, timeout: .seconds(2))
            XCTFail("expected a failure")
        } catch let failure as SourceFailure {
            XCTAssertEqual(failure, .unreachable)
        }
        try await group.shutdownGracefully()
    }
}
