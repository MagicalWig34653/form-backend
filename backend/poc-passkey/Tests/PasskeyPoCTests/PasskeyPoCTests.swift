// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import Crypto
import _CryptoExtras
@testable import PasskeyPoC

struct VectorFile: Decodable {
    struct Key: Decodable { let alg: Int; let publicKeyPem: String; let credentialId: String }
    struct Vector: Decodable {
        let name: String; let key: String; let storedSignCount: UInt32
        let challenge: String; let clientDataJSON: String; let authenticatorData: String
        let signature: String; let userHandle: String; let expect: String
    }
    let rpId: String; let origin: String; let userHandleText: String
    let keys: [String: Key]; let vectors: [Vector]
}

final class PasskeyPoCTests: XCTestCase {
    func load() throws -> VectorFile {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
    }
    func b(_ s: String) throws -> Data { try XCTUnwrap(Data(base64URLEncoded: s)) }

    func input(_ f: VectorFile, _ v: VectorFile.Vector) throws -> AssertionInput {
        AssertionInput(credentialID: try b(f.keys[v.key]!.credentialId), clientDataJSON: try b(v.clientDataJSON),
                       authenticatorData: try b(v.authenticatorData), signature: try b(v.signature),
                       userHandle: try b(v.userHandle))
    }
    func stored(_ f: VectorFile, _ v: VectorFile.Vector) throws -> StoredPasskey {
        StoredPasskey(credentialID: try b(f.keys[v.key]!.credentialId), userHandle: Data(f.userHandleText.utf8),
                      publicKeyPEM: f.keys[v.key]!.publicKeyPem, signCount: v.storedSignCount)
    }

    /// Every synthetic vector (ES256, RS256, EdDSA; positives and signed-but-faulty negatives).
    func testAllVectors() throws {
        let f = try load()
        XCTAssertGreaterThanOrEqual(f.vectors.count, 30)
        let verifier = AssertionVerifier(relyingParty: RelyingParty(rpID: f.rpId, origin: f.origin))
        for v in f.vectors {
            let hash = Data(SHA256.hash(data: try b(v.challenge)))
            do {
                let r = try verifier.verify(try input(f, v), stored: try stored(f, v), expectedChallengeSHA256: hash)
                XCTAssertEqual(v.expect, "ok", "\(v.name): accepted but expected \(v.expect)")
                XCTAssertTrue(r.userVerified)
            } catch let e as PasskeyError {
                XCTAssertEqual(String(describing: e), v.expect, "\(v.name)")
            }
        }
    }

    func testKeyFormatsParse() throws {
        let f = try load()
        var kinds = Set<String>()
        for (name, k) in f.keys {
            switch try PasskeyPublicKey(pem: k.publicKeyPem) {
            case .es256: kinds.insert("es256")
            case .rs256: kinds.insert("rs256")
            case .eddsa: kinds.insert("eddsa")
            }
            XCTAssertFalse(name.isEmpty)
        }
        XCTAssertEqual(kinds, ["es256", "rs256", "eddsa"])
        XCTAssertThrowsError(try PasskeyPublicKey(pem: "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"))
        XCTAssertThrowsError(try PasskeyPublicKey(pem: "garbage"))
    }

    func testCounterRule() {
        XCTAssertTrue(AssertionVerifier.counterPlausible(old: 0, new: 0))
        XCTAssertTrue(AssertionVerifier.counterPlausible(old: 0, new: 1))
        XCTAssertTrue(AssertionVerifier.counterPlausible(old: 4294967294, new: 4294967295))
        XCTAssertFalse(AssertionVerifier.counterPlausible(old: 5, new: 5))
        XCTAssertFalse(AssertionVerifier.counterPlausible(old: 5, new: 0))
        XCTAssertFalse(AssertionVerifier.counterPlausible(old: 4294967295, new: 4294967295))
    }

    // MARK: login flow (challenge single use, session binding, expiry, counter CAS)

    struct Fixture {
        let f: VectorFile; let v: VectorFile.Vector; let service: PasskeyLoginService
        let store: InMemoryChallengeStore; let repo: InMemoryPasskeyRepository
        let session = UUID(); let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    }
    func fixture(_ name: String) async throws -> Fixture {
        let f = try load()
        let v = try XCTUnwrap(f.vectors.first { $0.name == name })
        let store = InMemoryChallengeStore()
        let repo = InMemoryPasskeyRepository([try stored(f, v)])
        let svc = PasskeyLoginService(
            verifier: AssertionVerifier(relyingParty: RelyingParty(rpID: f.rpId, origin: f.origin)),
            challenges: store, passkeys: repo)
        let fx = Fixture(f: f, v: v, service: svc, store: store, repo: repo)
        await store.issue(sessionID: fx.session, challenge: try b(v.challenge), now: fx.t0)
        return fx
    }

    func testLoginZeroZeroSucceedsAndReplayFails() async throws {
        for name in ["es256_ok_counter_0_0", "rs256_ok_counter_0_0", "eddsa_ok_counter_0_0"] {
            let fx = try await fixture(name)
            let inp = try input(fx.f, fx.v)
            let p = try await fx.service.finish(sessionID: fx.session, input: inp, now: fx.t0.addingTimeInterval(5))
            XCTAssertEqual(p.userHandle, Data(fx.f.userHandleText.utf8))
            // Replay of the identical, valid assertion: counter 0/0 cannot detect it, the consumed challenge does.
            do {
                _ = try await fx.service.finish(sessionID: fx.session, input: inp, now: fx.t0.addingTimeInterval(6))
                XCTFail("replay accepted: \(name)")
            } catch { XCTAssertEqual(error as? PasskeyError, .challengeInvalid) }
        }
    }

    func testChallengeConsumedByFailedAttempt() async throws {
        let fx = try await fixture("es256_ok_counter_increase")
        var bad = try input(fx.f, fx.v)
        bad = AssertionInput(credentialID: bad.credentialID, clientDataJSON: bad.clientDataJSON,
                             authenticatorData: bad.authenticatorData, signature: Data(repeating: 1, count: 70), userHandle: bad.userHandle)
        do { _ = try await fx.service.finish(sessionID: fx.session, input: bad, now: fx.t0); XCTFail() }
        catch { XCTAssertEqual(error as? PasskeyError, .signatureInvalid) }
        // The genuine assertion with the same challenge no longer works.
        do { _ = try await fx.service.finish(sessionID: fx.session, input: try input(fx.f, fx.v), now: fx.t0); XCTFail() }
        catch { XCTAssertEqual(error as? PasskeyError, .challengeInvalid) }
    }

    func testChallengeSessionBindingAndExpiry() async throws {
        let fx = try await fixture("es256_ok_counter_0_0")
        do { _ = try await fx.service.finish(sessionID: UUID(), input: try input(fx.f, fx.v), now: fx.t0); XCTFail() }
        catch { XCTAssertEqual(error as? PasskeyError, .challengeInvalid) }
        let fy = try await fixture("es256_ok_counter_0_0")
        do { _ = try await fy.service.finish(sessionID: fy.session, input: try input(fy.f, fy.v), now: fy.t0.addingTimeInterval(121)); XCTFail() }
        catch { XCTAssertEqual(error as? PasskeyError, .challengeInvalid) }
        let fz = try await fixture("es256_ok_counter_0_0")
        _ = try await fz.service.finish(sessionID: fz.session, input: try input(fz.f, fz.v), now: fz.t0.addingTimeInterval(120))
    }

    func testConcurrentClaimExactlyOneWinner() async throws {
        let store = InMemoryChallengeStore(); let s = UUID(); let t = Date()
        await store.issue(sessionID: s, challenge: Data(repeating: 7, count: 32), now: t)
        let wins = await withTaskGroup(of: Bool.self) { g in
            for _ in 0..<50 { g.addTask { await store.consume(sessionID: s, now: t) != nil } }
            return await g.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        XCTAssertEqual(wins, 1)
    }

    func testUnknownCredentialAndUserHandle() async throws {
        let fx = try await fixture("es256_ok_counter_0_0")
        let i = try input(fx.f, fx.v)
        let other = AssertionInput(credentialID: Data([1, 2, 3]), clientDataJSON: i.clientDataJSON,
                                   authenticatorData: i.authenticatorData, signature: i.signature, userHandle: i.userHandle)
        do { _ = try await fx.service.finish(sessionID: fx.session, input: other, now: fx.t0); XCTFail() }
        catch { XCTAssertEqual(error as? PasskeyError, .unknownCredential) }
    }

    func testCounterAdvancesInRepository() async throws {
        let fx = try await fixture("es256_ok_counter_increase")
        let p = try await fx.service.finish(sessionID: fx.session, input: try input(fx.f, fx.v), now: fx.t0)
        let after = await fx.repo.find(credentialID: p.credentialID)
        XCTAssertEqual(after?.signCount, 6)
        let again = await fx.repo.advanceCounter(credentialID: p.credentialID, to: 6)
        XCTAssertFalse(again)
    }

    /// F9a: RSA modulus below 2048 bits is rejected (ADR 0006 Nr. 12); 2048 is accepted.
    func testShortRSAKeysRejected() throws {
        // Throw-away public keys generated with `openssl genrsa <bits>` (swift-crypto refuses to generate < 2048).
        let short: [(Int, String)] = [
            (1024, "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQCwu36+aFW4ORP/gHLxPgTp/J5BRQAgy8iCu2qChVuUZpxsc5BzgQ6QElcIoc2v3OdI0U6oCyjHkk1tHNR0iHQuLIaOy/h3TNmEdH7TzAKp0FjNunvFIcP7WJUk4ocs4eB+CJjKQR6HpJpp3/+JsfDt+1YKDKsCeDhNmzbJSy5TxQIDAQAB"),
            (2040, "MIIBITANBgkqhkiG9w0BAQEFAAOCAQ4AMIIBCQKCAQAAs1Wprgf8THdJOlYyMKiisNIaK5Qn9cH+hrau7E8duzDUfVaopRdaQxn9Q5Yo+XCVxtBkarUFSoq65UhkbsvDW/DwBbH9cOmg7Ld2/ew5DuZYNMkzAXKvd0vMzQRT3JCm1xJfiPPE0f2nLm+7Wupd67u7aHKZnbAqYTeu9VYxz2FtBBAlkBNSUdn99JrukedhKzmknc9kzSTjT16oCFTre0/D501dUFuzGamXhtq+/WHm1mbpQJCuzhIsnWW7cHzM9uoZgVjCDnGW8E4eXt7t4B3pASrzP/YwCbuBYTbvy2gcNvWPVHfnB7oFwgUDK8ZjzvHzUVcQsub9vVvyPBbfAgMBAAE="),
            (2047, "MIIBITANBgkqhkiG9w0BAQEFAAOCAQ4AMIIBCQKCAQB395HLd8hRTnHUtJAcxLTSQbpLSX2cnSJN/KsZIHE+MR3T82wJUu8V/sgjJv1eY3GJaBG5AO2VGNwk+6oOrm6xej0rCAcP6VBm1wDcoQIuW3B1WReFsaWxUiqpjcoaZ4P2+uC+CZ2NBmTaFPKVa5bEQJuU959sj4NrcF9/NGlRw+q6o9knfmza1h0+c5sSRWu0g7DdoipJTUhVckW+PcvmOxaH/MC2r4lX2MigtFF927SLyLCf/jvNVxbf7QO+s2W6SKYJ5T66IP8ghMGF9OwTsWlTD0nE+VE8177TLBCSQHNK0zrtwI4XrEerOACTwdpX72LPpCGSagub0NhjPj33AgMBAAE=")
        ]
        for (bits, b64) in short {
            let der = try XCTUnwrap(Data(base64Encoded: b64))
            XCTAssertThrowsError(try PasskeyPublicKey(spkiDER: der), "\(bits)") {
                XCTAssertEqual($0 as? PasskeyError, .unsupportedKey)
            }
            // The size check measures the modulus itself: swift-crypto 3.15.1 reports keySizeInBits rounded up to bytes.
        }
        let ok = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        XCTAssertNoThrow(try PasskeyPublicKey(spkiDER: ok.publicKey.derRepresentation))
    }

    /// F9b: every login failure maps to the same outward category.
    func testExternalCategoryIsUniform() {
        let all: [PasskeyError] = [.clientDataInvalid, .wrongType, .challengeMismatch, .originMismatch, .rpIdHashMismatch,
                                   .userNotPresent, .userNotVerified, .signatureInvalid, .authenticatorDataInvalid, .counterRegression,
                                   .unsupportedKey, .userHandleMismatch, .unknownCredential, .challengeInvalid]
        XCTAssertEqual(Set(all.map { $0.external }), [.authenticationFailed])
        XCTAssertEqual(PasskeyError.externalCode, "authentication_failed")
    }
}
