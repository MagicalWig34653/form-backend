// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import Foundation
import Crypto
@testable import FormCrypto

final class FormCryptoTests: XCTestCase {
    func fixture(_ name: String) throws -> [String: Any] {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }
    func data(_ m: [String: Any], _ key: String) throws -> Data { try Data(hex: m[key] as! String) }
    func testRFC9180() throws {
        let v = try fixture("rfc9180")
        XCTAssertEqual(v["mode"] as? Int, 0); XCTAssertEqual(v["kem_id"] as? Int, 32)
        XCTAssertEqual(v["kdf_id"] as? Int, 1); XCTAssertEqual(v["aead_id"] as? Int, 2)
        let sk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(v,"skEm"))
        XCTAssertEqual(sk.publicKey.rawRepresentation, try data(v,"enc"))
        let s = try HPKE.schedule(privateKey: sk, peer: data(v,"pkRm"), enc: data(v,"enc"), recipient: data(v,"pkRm"), info: data(v,"info"))
        XCTAssertEqual(s.shared, try data(v,"shared_secret")); XCTAssertEqual(s.context, try data(v,"key_schedule_context"))
        XCTAssertEqual(s.key, try data(v,"key")); XCTAssertEqual(s.nonce, try data(v,"base_nonce"))
        let e = (v["encryptions"] as! [[String: Any]])[0]
        let sealed = try HPKE.seal(data(e,"pt"), recipient: data(v,"pkRm"), info: data(v,"info"), aad: data(e,"aad"), ephemeral: sk)
        XCTAssertEqual(sealed.ciphertext, try data(e,"ct"))
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(v,"skRm"))
        XCTAssertEqual(try HPKE.open(sealed.ciphertext, enc: sealed.enc, recipient: recipient, info: data(v,"info"), aad: data(e,"aad")), try data(e,"pt"))
        XCTAssertThrowsError(try HPKE.open(sealed.ciphertext, enc: sealed.enc, recipient: recipient, info: Data(), aad: data(e,"aad")))
        XCTAssertThrowsError(try HPKE.open(sealed.ciphertext, enc: sealed.enc, recipient: recipient, info: data(v,"info"), aad: Data()))
    }
    func testPHPPacketsAndSwiftExport() throws {
        let m = try fixture("synthetic")
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(m,"sk"))
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(m,"skE"))
        XCTAssertEqual(recipient.publicKey.rawRepresentation, try data(m,"pk"))
        var output = [[String: String]]()
        for p in m["packets"] as! [[String: Any]] {
            let pt = try data(p,"plaintext"), wire = p["packet"] as! String
            let parsed = try PackageV2(wire)
            XCTAssertEqual(parsed.wire, wire); XCTAssertEqual(try parsed.open(recipient: recipient), pt)
            let generated = try PackageV2.seal(pt, recipient: data(m,"pk"), cek: data(m,"cek"), iv: data(m,"iv"), ephemeral: ephemeral)
            XCTAssertEqual(generated.wire, wire)
            // Independent random Swift writer output is opened by the PHP suite.
            output.append(["plaintext": pt.hex, "packet": try PackageV2.seal(pt, recipient: data(m,"pk")).wire])
        }
        var signatures = [[String: String]]()
        for c in m["canonical"] as! [[String: Any]] {
            let text = try data(c,"text"), signature = try RequestSignature.sign(text, sodiumSecretKey: data(m,"seed") + data(m,"signPublic"))
            XCTAssertTrue(Ed25519Strict.isValidSignature(signature, for: text, publicKey: try data(m,"signPublic")))
            signatures.append(["text": text.hex, "signature": signature.hex])
        }
        let outputURL = URL(fileURLWithPath: "/dev/null")
        // Written to the build directory, not the source tree (hermetic); run-tests.sh copies it for the PHP check.
        _ = outputURL
        let exportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FORM_SWIFT_EXPORT"] ?? (NSTemporaryDirectory() + "swift-output.json"))
        try JSONSerialization.data(withJSONObject: ["packets": output, "signatures": signatures], options: [.prettyPrinted, .sortedKeys]).write(to: exportURL)
    }
    func testCanonicalPHPAndEd25519() throws {
        let m = try fixture("synthetic")
        let fields: [PHPValue] = [
            .array([]),
            .array([("z", .string("Grüße / 🌍")), ("a", .array([("x", .boolean(true)), ("n", .null), ("i", .integer(-42))])), ("line", .string("\0\n\t\u{2028}\u{2029}"))]),
            .array([("2", .string("two")), ("0", .string("zero"))]),
            .array([("1", .string("one")), ("0", .string("zero"))]),
            .array([("10", .string("ten")), ("2", .string("two")), ("01", .string("leading"))]),
            .array([("list", .array([("0", .string("b")), ("1", .string("a"))])), ("empty", .array([]))])
        ]
        for (i, c) in (m["canonical"] as! [[String: Any]]).enumerated() {
            let files: [(String, FileField)] = i == 1 ? [("upload", .multiple([
                .single(SignedFile(name: "b.bin", type: "application/octet-stream", error: 0, size: 3, content: Data([0,255,1]))),
                .single(SignedFile(name: "skip", error: 4)), .single(SignedFile(name: "missing", error: 0))]))] : []
            let canonical = try RequestSignature.canonical(fields: fields[i], files: files)
            XCTAssertEqual(canonical, try data(c,"canonical"))
            let text = try RequestSignature.text(method: "post", path: "https://example.invalid/api/v2/submit///?ignored=yes", formID: "a b/ü", timestamp: "1793145600", canonical: canonical)
            XCTAssertEqual(text, try data(c,"text"))
            let signature = try data(c,"signature"), pk = try data(m,"signPublic")
            func verify(_ sig: Data = signature, method: String = "post", route: SignatureRoute = .submit, form: String = "a b/ü", ts: String = "1793145600",
                        body: Data = canonical, now: Int64 = 1793145600) -> Bool {
                RequestSignature.verify(signature: sig, method: method, route: route, formID: form, timestamp: ts, canonical: body, publicKey: pk, now: now)
            }
            XCTAssertTrue(verify())
            XCTAssertFalse(verify(ts: "1793145601", now: 1793145601))
            XCTAssertFalse(verify(now: 1793145901))
            // F7: everything is bound by the signature, nothing is taken from the caller.
            XCTAssertFalse(verify(method: "GET")); XCTAssertFalse(verify(route: .form)); XCTAssertFalse(verify(form: "other"))
            XCTAssertFalse(verify(body: canonical + Data([0x20])))
        }
        XCTAssertThrowsError(try RequestSignature.sign(Data(), sodiumSecretKey: Data(repeating: 0, count: 64)))
        XCTAssertThrowsError(try RequestSignature.sign(Data(), sodiumSecretKey: Data()))
        XCTAssertThrowsError(try PHPValue.utf8(Data([255])))
        XCTAssertThrowsError(try RequestSignature.canonical(fields: .array([("f", .unsupportedFloat(1.2))])))
        XCTAssertThrowsError(try RequestSignature.canonical(fields: .array([("a", .null), ("a", .null)])))
        for ts in ["00", "01", "1\n", " 1", "9223372036854775808", "-1", ""] { XCTAssertFalse(RequestSignature.validTimestamp(ts, now: 0)) }
        XCTAssertTrue(RequestSignature.validTimestamp("300", now: 0)); XCTAssertTrue(RequestSignature.validTimestamp("0", now: 300))
        XCTAssertFalse(RequestSignature.validTimestamp("301", now: 0)); XCTAssertFalse(RequestSignature.validTimestamp("0", now: .min))
    }
    func testStrictParser() throws {
        let m = try fixture("synthetic"), p = (m["packets"] as! [[String: Any]])[0]
        let wire = p["packet"] as! String, parts = wire.components(separatedBy: "|")
        for bad in [wire + "\n", " " + wire, wire + "|", wire.replacingOccurrences(of: "KUBUS-AEAD:2", with: "KUBUS-AEAD:1"), wire.replacingOccurrences(of: "hpke", with: "HPKE")] { XCTAssertThrowsError(try PackageV2(bad)) }
        for index in [1,3,4,6] {
            var q = parts; q[index] = ""; XCTAssertThrowsError(try PackageV2(q.joined(separator: "|")))
        }
        var q = parts; q[1] = q[1].uppercased(); XCTAssertThrowsError(try PackageV2(q.joined(separator: "|")))
        for b64 in ["AB==", "AA", "AA===", "AA==\n", "_A==", "AA== "] {
            var q = parts; q[5] = b64; XCTAssertThrowsError(try PackageV2(q.joined(separator: "|")))
        }
        XCTAssertEqual(try PackageV2(wire).ciphertext, Data())
    }
    func testAuthenticationAndInvalidKeys() throws {
        let m = try fixture("synthetic"), p = (m["packets"] as! [[String: Any]])[1]
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data(m,"sk"))
        let wire = p["packet"] as! String
        for field in [0,1,2,3,4] {
            var parts = wire.components(separatedBy: "|"); var wrap = parts[3].components(separatedBy: ":")
            let s = field < 2 ? wrap[field] : parts[field + 2]
            var d = Data(base64Encoded: s)!; d[d.startIndex] ^= 1
            if field < 2 { wrap[field] = d.base64EncodedString(); parts[3] = wrap.joined(separator: ":") }
            else { parts[field + 2] = d.base64EncodedString() }
            XCTAssertThrowsError(try PackageV2(parts.joined(separator: "|")).open(recipient: recipient))
        }
        XCTAssertThrowsError(try PackageV2(wire).open(recipient: Curve25519.KeyAgreement.PrivateKey()))
        var parts = wire.components(separatedBy: "|"); parts[1] = "0000000000000000"
        XCTAssertThrowsError(try PackageV2(parts.joined(separator: "|")).open(recipient: recipient))
        XCTAssertThrowsError(try HPKE.seal(Data(), recipient: Data(repeating: 0, count: 32), info: Data(), aad: Data()))
        XCTAssertThrowsError(try HPKE.seal(Data(), recipient: Data(repeating: 1, count: 31), info: Data(), aad: Data()))
        XCTAssertThrowsError(try keyID(Data()))
    }
    func testSymReadOnlyWrap() throws {
        let m = try fixture("synthetic"), sk = try data(m,"sk")
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sk)
        let kid = try keyID(recipient.publicKey.rawRepresentation), cek = try data(m,"cek"), iv = try data(m,"iv")
        let kek = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sk), salt: Data(), info: bytes("kubus-langzeit v1"), outputByteCount: 32).withUnsafeBytes { Data($0) }
        let wrap = try sealGCM(cek, key: kek, nonce: iv, aad: bytes(kid))
        let payload = try sealGCM(Data(), key: cek, nonce: iv, aad: bytes("KUBUS-AEAD:2"))
        let p = try PackageV2("KUBUS-AEAD:2|\(kid)|sym|\(iv.base64EncodedString()):\(wrap.base64EncodedString())|\(iv.base64EncodedString())||\(payload.base64EncodedString())")
        XCTAssertEqual(try p.open(recipient: recipient), Data())
        XCTAssertEqual(p.wire, m["symPacket"] as? String)
        XCTAssertEqual(try PackageV2(m["symPacket"] as! String).open(recipient: recipient), Data())
    }

    // MARK: F1 strict Ed25519 (contract A7)
    func testEd25519StrictVectors() throws {
        let cases = try fixture("ed25519-strict")["cases"] as! [[String: Any]]
        XCTAssertEqual(cases.count, 15)
        for c in cases {
            let ok = Ed25519Strict.isValidSignature(try data(c, "signature"), for: try data(c, "message"), publicKey: try data(c, "publicKey"))
            XCTAssertEqual(ok, c["expected"] as? Bool, c["id"] as! String)
        }
        // Scalar boundary: S = L - 1 is still < L (passes the S check, then fails verification); S = L, L+1 rejected.
        let L = Ed25519Strict.order
        XCTAssertFalse(Ed25519Strict.lessThan(L, L)); XCTAssertTrue(Ed25519Strict.lessThan(L.enumerated().map { $0.offset == 0 ? $0.element - 1 : $0.element }, L))
        // All eight small-order points (both sign bits) and non-canonical y >= p are rejected.
        for y in Ed25519Strict.smallOrderY {
            XCTAssertTrue(Ed25519Strict.hasSmallOrder(y)); var neg = y; neg[31] |= 0x80; XCTAssertTrue(Ed25519Strict.hasSmallOrder(neg))
        }
        XCTAssertFalse(Ed25519Strict.isCanonicalPoint([0xed] + [UInt8](repeating: 0xff, count: 30) + [0x7f]))
        XCTAssertTrue(Ed25519Strict.isCanonicalPoint([0xec] + [UInt8](repeating: 0xff, count: 30) + [0x7f]))
    }

    // MARK: F6 vectors generated from the legacy SDK/backend code (sdk/php/tests/alt_sdk_vectors.php)
    func testLegacyCodeVectors() throws {
        let m = try fixture("alt-sdk")
        func f(_ post: [(String, PHPValue)]) -> PHPValue { .array(post) }
        func chain(_ n: Int, _ leaf: PHPValue) -> PHPValue { var v = leaf; for i in 0..<n { v = .array([("0", v)]); _ = i }; return v }
        let file = { (n: String, t: String, size: Int64, c: Data?) in FileField.single(SignedFile(name: n, type: t, error: 0, size: size, content: c)) }
        let swiftBodies: [String: (PHPValue, [(String, FileField)])] = [
            "empty": (f([]), []),
            "unordered-list": (f([("2", .string("two")), ("0", .string("zero"))]), []),
            "list-order": (f([("1", .string("one")), ("0", .string("zero"))]), []),
            "string-keys": (f([("10", .string("ten")), ("2", .string("two")), ("01", .string("leading"))]), []),
            "nested-list": (f([("list", .array([("0", .string("b")), ("1", .string("a"))])), ("empty", .array([]))]), []),
            "numeric-edge-keys": (f([("-0", .string("a")), ("1.5", .string("b")), ("9223372036854775807", .string("c")), ("9223372036854775808", .string("d")), ("", .string("empty"))]), []),
            "scalars": (f([("max", .integer(.max)), ("min", .integer(.min)), ("zero", .integer(0)), ("f", .boolean(false)), ("t", .boolean(true)), ("n", .null)]), []),
            "controls-and-specials": (f([("k", .string("\u{01}\u{1f}\u{7f}\u{08}\u{0c}\r")), ("html", .string("<a href='x'>&\"</a> / \\")), ("astral", .string("\u{10FFFF}\u{FFFF}")), ("bom", .string("\u{FEFF}a"))]), []),
            "bom-key": (f([("\u{FEFF}k", .string("v")), ("ü", .integer(1)), ("z", .integer(2)), ("Z", .integer(3)), ("é", .integer(4))]), []),
            "depth-511": (f([("d", chain(510, .string("x")))]), []),
            "files-only": (f([]), [("f", file("a", "t", 1, Data("x".utf8))), ("g", .single(SignedFile(name: "", type: "", error: 4, size: 0, content: nil)))]),
            "files-empty-multi": (f([]), [("m", .multiple([.single(SignedFile(error: 4)), .single(SignedFile(error: 4))]))]),
            "files-list-keys": (f([]), [("1", file("a", "", 0, Data())), ("0", file("b", "", 0, Data("y".utf8)))]),
        ]
        var checked = 0
        for b in m["bodies"] as! [[String: Any]] {
            let id = b["id"] as! String
            if b["error"] != nil {  // legacy json_encode failed (depth 512) -> Swift must refuse too
                XCTAssertEqual(id, "depth-512")
                XCTAssertThrowsError(try RequestSignature.canonical(fields: f([("d", chain(511, .string("x")))])), id) {
                    guard case FormCryptoError.depthExceeded = $0 else { return XCTFail("wrong error") }
                }
                checked += 1; continue
            }
            if id == "mixed" { continue }  // covered by synthetic.json (canonical-1)
            guard let (post, files) = swiftBodies[id] else { XCTFail("missing swift input for \(id)"); continue }
            let canonical = try RequestSignature.canonical(fields: post, files: files)
            XCTAssertEqual(canonical, try data(b, "canonical"), id)
            XCTAssertEqual(sha256(canonical).hex, b["bodyHash"] as? String, id)
            checked += 1
        }
        XCTAssertEqual(checked, 14)
        var textsChecked = 0
        let pk = try data(m, "publicKey")
        for t in m["paths"] as! [[String: Any]] {
            let id = t["id"] as! String
            let expected = try data(t, "text")
            let ts = t["timestamp"] as! String
            let canonical = try data(m, "emptyBodyCanonical")
            if !RequestSignature.isDecimalTimestamp(ts) { // contract: only canonical decimal timestamps are signed by the new core
                XCTAssertThrowsError(try RequestSignature.text(method: t["method"] as! String, path: t["path"] as! String, formID: t["formID"] as! String, timestamp: ts, canonical: canonical)); continue
            }
            let got = try RequestSignature.text(method: t["method"] as! String, path: t["path"] as! String, formID: t["formID"] as! String, timestamp: ts, canonical: canonical)
            XCTAssertEqual(got, expected, "\(id) path=\(t["path"] as! String)")
            XCTAssertTrue(Ed25519Strict.isValidSignature(try data(t, "signature"), for: expected, publicKey: pk), id)
            textsChecked += 1
        }
        XCTAssertGreaterThanOrEqual(textsChecked, 30)
    }

    // MARK: F8 robustness
    func testNestingDepthLimitMatchesPHP() throws {
        func chain(_ n: Int) -> PHPValue { var v = PHPValue.string("x"); for _ in 0..<n { v = .array([("0", v)]) }; return v }
        XCTAssertNoThrow(try RequestSignature.canonical(fields: .array([("d", chain(510))])))
        XCTAssertThrowsError(try RequestSignature.canonical(fields: .array([("d", chain(511))])))
        XCTAssertThrowsError(try RequestSignature.canonical(fields: .array([("d", chain(5_000))])))  // no stack overflow
    }
    func testBOMAndInvalidUTF8() throws {
        let bom = Data([0xEF, 0xBB, 0xBF, 0x61])
        guard case .string(let s) = try PHPValue.utf8(bom) else { return XCTFail() }
        XCTAssertEqual(Array(s.utf8), [0xEF, 0xBB, 0xBF, 0x61])
        XCTAssertEqual(try RequestSignature.canonical(fields: .array([("k", .string(s))])), Data("{\"fields\":{\"k\":\"\u{FEFF}a\"},\"files\":[]}".utf8))
        for bad in [Data([0xFF]), Data([0xC0, 0x80]), Data([0xED, 0xA0, 0x80]), Data([0xE2, 0x82])] { XCTAssertThrowsError(try PHPValue.utf8(bad)) }
    }
    func testHexParsingIsStrict() {
        XCTAssertThrowsError(try Data(hex: "+f")); XCTAssertThrowsError(try Data(hex: "-1")); XCTAssertThrowsError(try Data(hex: "0x")); XCTAssertThrowsError(try Data(hex: "f"))
        XCTAssertEqual(try Data(hex: "0aFf"), Data([10, 255]))
    }
    func testSigningTextRejectsBadInputs() {
        XCTAssertThrowsError(try RequestSignature.signingText(route: .submit, formID: "x", timestamp: "01", canonical: Data()))
        XCTAssertThrowsError(try RequestSignature.signingText(method: "PO\nST", route: .submit, formID: "x", timestamp: "1", canonical: Data()))
        XCTAssertThrowsError(try RequestSignature.signingText(method: "", route: .submit, formID: "x", timestamp: "1", canonical: Data()))
    }
}
