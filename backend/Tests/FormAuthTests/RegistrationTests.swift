// SPDX-License-Identifier: AGPL-3.0-only
import Crypto
import Foundation
import XCTest
@testable import FormAuth

final class RegistrationTests: XCTestCase {
    private let rp = RelyingParty(rpID: "admin.example.test", origin: "https://admin.example.test")
    private var verifier: RegistrationVerifier { RegistrationVerifier(relyingParty: rp) }
    private let challenge = Data((0..<32).map { UInt8($0) })
    private var chash: Data { Data(SHA256.hash(data: challenge)) }

    private func auth(_ k: SyntheticAuthenticator.Kind) -> SyntheticAuthenticator { SyntheticAuthenticator(k, rpID: rp.rpID, origin: rp.origin) }

    func testAllThreeAlgorithmsRegisterAndTheStoredKeyVerifiesRealAssertions() throws {
        for kind in [SyntheticAuthenticator.Kind.es256, .eddsa, .rs256] {
            let a = auth(kind)
            let (cd, att) = a.registration(challenge: challenge)
            let r = try verifier.verify(clientDataJSON: cd, attestationObject: att, expectedChallengeSHA256: chash)
            XCTAssertEqual(r.credentialID, a.credentialID)
            XCTAssertEqual(r.coseAlgorithm, kind == .es256 ? -7 : kind == .eddsa ? -8 : -257)
            XCTAssertTrue(r.publicKeyPEM.hasPrefix("-----BEGIN PUBLIC KEY-----\n") && r.publicKeyPEM.hasSuffix("-----END PUBLIC KEY-----\n"))
            // The PEM the registration stores must be accepted by the LOGIN verifier and check a real signature.
            let stored = StoredPasskey(credentialID: r.credentialID, userHandle: Data("u".utf8), publicKeyPEM: r.publicKeyPEM, signCount: r.signCount)
            let loginChallenge = Data((0..<32).map { UInt8(100 + $0) })
            let (ad, cdj, sig) = a.assertion(challenge: loginChallenge)
            let v = AssertionVerifier(relyingParty: rp)
            let ok = try v.verify(AssertionInput(credentialID: r.credentialID, clientDataJSON: cdj, authenticatorData: ad, signature: sig, userHandle: nil),
                                  stored: stored, expectedChallengeSHA256: Data(SHA256.hash(data: loginChallenge)))
            XCTAssertEqual(ok.newSignCount, 1, "\(kind)")
        }
    }

    func testBackupEligibleFlagAndExtensionData() throws {
        let a = auth(.es256)
        let (cd, att) = a.registration(challenge: challenge, flags: 0x45 | 0x08)
        XCTAssertTrue(try verifier.verify(clientDataJSON: cd, attestationObject: att, expectedChallengeSHA256: chash).backupEligible)
        // ED flag with a well-formed CBOR extension map after the key is allowed
        let (cd2, att2) = a.registration(challenge: challenge, flags: 0x45 | 0x80, trailing: CBOREnc.map([(CBOREnc.text("credProtect"), CBOREnc.int(2))]))
        XCTAssertNoThrow(try verifier.verify(clientDataJSON: cd2, attestationObject: att2, expectedChallengeSHA256: chash))
    }

    private func expect(_ e: RegistrationError, _ pair: (clientDataJSON: Data, attestationObject: Data), hash h: Data? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try verifier.verify(clientDataJSON: pair.clientDataJSON, attestationObject: pair.attestationObject, expectedChallengeSHA256: h ?? chash), file: file, line: line) {
            XCTAssertEqual($0 as? RegistrationError, e, file: file, line: line)
        }
    }

    func testEveryFaultIsRejectedWithItsInternalReason() {
        let a = auth(.es256)
        expect(.wrongType, a.registration(challenge: challenge, type: "webauthn.get"))
        expect(.challengeMismatch, a.registration(challenge: Data(repeating: 9, count: 32)))
        expect(.originMismatch, a.registration(challenge: challenge, origin: "https://admin.example.test.evil.test"))
        expect(.originMismatch, a.registration(challenge: challenge, origin: "https://admin.example.test/"))
        expect(.rpIdHashMismatch, a.registration(challenge: challenge, rpID: "evil.test"))
        expect(.userNotPresent, a.registration(challenge: challenge, flags: 0x44))
        expect(.userNotVerified, a.registration(challenge: challenge, flags: 0x41))
        expect(.noCredentialData, a.registration(challenge: challenge, flags: 0x05))
        expect(.clientDataInvalid, (Data("not json".utf8), a.registration(challenge: challenge).attestationObject))
        expect(.attestationInvalid, (a.clientData(type: "webauthn.create", challenge: challenge), Data([0xA0])))                                  // empty map
        expect(.attestationInvalid, (a.clientData(type: "webauthn.create", challenge: challenge), a.registration(challenge: challenge).attestationObject + Data([0])))   // trailing byte
        expect(.keyInvalid, a.registration(challenge: challenge, trailing: Data([0xFF, 0xFF])))                                                    // garbage after the key without ED flag
    }

    func testKeyProblems() {
        let a = auth(.es256)
        let x = Data(repeating: 1, count: 32), y = Data(repeating: 2, count: 32)
        func ec(alg: Int = -7, crv: Int = 1, x: Data, y: Data) -> Data {
            CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(2)), (CBOREnc.int(3), CBOREnc.int(alg)), (CBOREnc.int(-1), CBOREnc.int(crv)), (CBOREnc.int(-2), CBOREnc.bytes(x)), (CBOREnc.int(-3), CBOREnc.bytes(y))])
        }
        expect(.keyInvalid, a.registration(challenge: challenge, cose: ec(x: x, y: y)))                                  // point not on the curve
        expect(.keyInvalid, a.registration(challenge: challenge, cose: ec(crv: 2, x: x, y: y)))                          // P-384 curve id
        expect(.keyInvalid, a.registration(challenge: challenge, cose: ec(x: Data(count: 31), y: y)))                    // wrong coordinate length
        expect(.algorithmNotAllowed, a.registration(challenge: challenge, cose: ec(alg: -35, x: x, y: y)))               // ES384
        expect(.algorithmNotAllowed, a.registration(challenge: challenge, cose: CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(4)), (CBOREnc.int(3), CBOREnc.int(5))])))
        expect(.keyInvalid, a.registration(challenge: challenge, cose: CBOREnc.map([])))
        // RSA below 2048 bits and with an absurd exponent
        let smallN = Data([0x80]) + Data(repeating: 0xAB, count: 127) + Data([0x01])   // 1024 bit
        expect(.keyInvalid, a.registration(challenge: challenge, cose: CBOREnc.map([(CBOREnc.int(1), CBOREnc.int(3)), (CBOREnc.int(3), CBOREnc.int(-257)), (CBOREnc.int(-1), CBOREnc.bytes(smallN)), (CBOREnc.int(-2), CBOREnc.bytes(Data([1, 0, 1])))])))
    }

    func testCBORReaderIsStrict() {
        XCTAssertThrowsError(try CBOR.decode(Data([0x9F, 0x01, 0xFF])))                         // indefinite array
        XCTAssertThrowsError(try CBOR.decode(Data([0xA2, 0x01, 0x01, 0x01, 0x02])))             // duplicate key
        XCTAssertThrowsError(try CBOR.decode(Data([0xC1, 0x01])))                               // tag
        XCTAssertThrowsError(try CBOR.decode(Data([0xF9, 0x3C, 0x00])))                         // float
        XCTAssertThrowsError(try CBOR.decode(Data([0x58, 0x05, 0x01])))                         // truncated byte string
        XCTAssertThrowsError(try CBOR.decode(Data([0x62, 0xFF, 0xFE])))                         // invalid UTF-8 text
        XCTAssertThrowsError(try CBOR.decode(Data(repeating: 0x81, count: 20) + Data([0x00])))  // nested too deep
        XCTAssertEqual(try CBOR.decode(Data([0x20])).0.int, -1)
        XCTAssertEqual(try CBOR.decode(Data([0x18, 0x64])).0.int, 100)
        XCTAssertEqual(try CBOR.decode(Data([0xA1, 0x61, 0x61, 0x01])).0.value(forText: "a")?.int, 1)
    }
}
