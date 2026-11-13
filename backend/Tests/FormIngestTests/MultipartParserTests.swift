// SPDX-License-Identifier: AGPL-3.0-only
import FormCrypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLRequest/URLSession live here on Linux
#endif
import Vapor
import XCTest
@testable import FormIngest

/// Review Astra 2 L1 (one reading per body) and M5 (budgets while parsing). DB-free.
private typealias MP = FormIngest.MultipartParser

final class MultipartParserTests: XCTestCase {
    /// The PHP binary for the differential tests. Without one the L1 evidence is missing: that is reported loudly on stderr, and with
    /// FORM_REQUIRE_PHP=1 (CI) it is a failure instead of a skip (gegenlesen Astra 2).
    static func php(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        if let p = ["/opt/homebrew/bin/php", "/usr/local/bin/php", "/usr/bin/php"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return p }
        let msg = "WARNUNG: kein php gefunden – PHP-Differentialtest (Review Astra 2 L1) NICHT gelaufen"
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        if ProcessInfo.processInfo.environment["FORM_REQUIRE_PHP"] == "1" { XCTFail(msg, file: file, line: line); throw XCTSkip(msg) }
        throw XCTSkip(msg)
    }

    private let b = "fbXYZ"
    private let pdf = "%PDF-1.4\n%fake\n"
    private func parse(_ s: String) throws -> MP.Result { try MP.parse(Array(s.utf8), boundary: b) }
    private func rejects(_ s: String, _ why: String, status: HTTPResponseStatus = .badRequest, line: UInt = #line) {
        do { _ = try parse(s); XCTFail("accepted: \(why)", line: line) }
        catch let e as Abort { XCTAssertEqual(e.status, status, why, line: line) }
        catch { XCTFail("\(error)", line: line) }
    }
    private func text(_ name: String, _ value: String) -> String { "--\(b)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n" }
    private func file(_ name: String, _ fn: String = "a.pdf", _ content: String? = nil) -> String {
        "--\(b)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(fn)\"\r\nContent-Type: application/pdf\r\n\r\n\(content ?? pdf)\r\n"
    }
    private var close: String { "--\(b)--\r\n" }

    func testWellFormedBodyIsParsed() throws {
        let r = try parse(text("a", "1 2") + text("x[]", "ä&=") + file("doc") + close)
        XCTAssertEqual(String(decoding: r.urlencoded, as: UTF8.self), "a=1%202&x%5B%5D=%C3%A4%26%3D")
        XCTAssertEqual(r.files.map { $0.field }, ["doc"]); XCTAssertEqual(r.files.first?.data, Data(pdf.utf8))
        XCTAssertNoThrow(try parse(text("a", "1") + "--\(b)--"), "closing delimiter at the very end is fine")
        rejects("--\(b)  \r\nContent-Disposition: form-data; name=\"a\"\r\n\r\n1\r\n" + close, "transport padding after a delimiter: PHP does not accept it")
    }

    private func mediaType(_ v: String) -> HTTPMediaType? { HTTPHeaders([("Content-Type", v)]).contentType }

    /// Codex gegenlesen 7: media type and parameter names are case-insensitive, the boundary value is kept as sent.
    func testBoundaryIsFoundWithoutRegardToCase() {
        for ct in ["multipart/form-data; boundary=fbXYZ", "Multipart/Form-Data; Boundary=\"fbXYZ\"", "MULTIPART/FORM-DATA; BOUNDARY=fbXYZ"] {
            XCTAssertEqual(mediaType(ct).flatMap(MP.boundary(of:)), "fbXYZ", ct)
        }
        XCTAssertEqual(mediaType("multipart/form-data; boundary=AbC").flatMap(MP.boundary(of:)), "AbC", "the value keeps its case")
        XCTAssertNil(mediaType("multipart/form-data; boundary=a; Boundary=b").flatMap(MP.boundary(of:)), "two boundaries are ambiguous")
        XCTAssertNil(mediaType("multipart/mixed; boundary=a").flatMap(MP.boundary(of:)))
    }

    /// Gegenlesen Astra 2: umlauts (NFC and NFD), escaped quotes, header and parameter names in any case, unquoted tokens.
    func testUmlautFileNamesAndCaseVariantsAreAccepted() throws {
        let nfc = "Lebenslauf_Müller_ä.pdf", nfd = "Lebenslauf_Mu\u{0308}ller.pdf"
        for fn in [nfc, nfd] {
            let r = try parse(file("doc", fn) + close)
            XCTAssertEqual(r.files.first.map { Array($0.filename.utf8) }, Array(fn.utf8), "file name bytes unchanged (no normalisation)")
        }
        let r = try parse("--\(b)\r\ncontent-disposition: FORM-DATA; NAME=\"doc\"; FILENAME=\"a \\\"b\\\".pdf\"\r\nCONTENT-TYPE: Application/PDF\r\n\r\n\(pdf)\r\n"
            + "--\(b)\r\nContent-Disposition: form-data; name=feld\r\n\r\nwert\r\n" + close)
        XCTAssertEqual(r.files.first?.filename, "a \"b\".pdf"); XCTAssertEqual(r.files.first?.field, "doc"); XCTAssertEqual(r.files.first?.declaredType, "application/pdf")
        XCTAssertEqual(String(decoding: r.urlencoded, as: UTF8.self), "feld=wert")
        XCTAssertEqual(String(decoding: try parse(text("Straße", "Größe") + close).urlencoded, as: UTF8.self), "Stra%C3%9Fe=Gr%C3%B6%C3%9Fe")
    }

    func testDuplicateHeadersAreRefused() {
        rejects("--\(b)\r\nContent-Disposition: form-data; name=\"a\"\r\nContent-Disposition: form-data; name=\"b\"\r\n\r\n1\r\n" + close, "two Content-Disposition")
        rejects("--\(b)\r\nContent-Disposition: form-data; name=\"d\"; filename=\"a.pdf\"\r\nContent-Type: application/pdf\r\nContent-Type: image/png\r\n\r\n\(pdf)\r\n" + close, "two Content-Type")
        rejects("--\(b)\r\ncontent-disposition: form-data; name=\"a\"\r\nCONTENT-DISPOSITION: form-data; name=\"a\"\r\n\r\n1\r\n" + close, "case-insensitive duplicate")
    }

    func testClosingDelimiterMustEndTheBody() {
        rejects(text("a", "1") + "--\(b)--garbage", "rest after the closing delimiter")
        rejects(text("a", "1") + "--\(b)--\r\nepilogue", "epilogue")
        rejects(text("a", "1") + "--\(b)--\r\n\r\n", "more than one line end")
        rejects("preamble\r\n" + text("a", "1") + close, "preamble")
    }

    func testParameterSeparatorsAndExtensions() {
        let cd = { (v: String) in "--\(self.b)\r\nContent-Disposition: \(v)\r\n\r\n1\r\n" + self.close }
        rejects(cd("form-data; name=\"a\" filename=\"x.pdf\""), "missing ; after a quoted value")
        rejects(cd("form-data; name=\"a\";; filename=\"x.pdf\""), "empty parameter")
        rejects(cd("form-data; name*=UTF-8''a"), "RFC 2231 name")
        rejects(cd("form-data; name=\"a\"; filename*=UTF-8''x.pdf"), "RFC 5987 filename")
        rejects(cd("form-data; name=\"a\"; size=3"), "unknown parameter")
        rejects(cd("form-data; name=\"a"), "unterminated quote")
        rejects("--\(b)\r\nContent-Disposition: form-data;\r\n name=\"a\"\r\n\r\n1\r\n" + close, "folded header")
        XCTAssertNoThrow(try parse(cd("form-data; name=a")), "token value")
        XCTAssertNoThrow(try parse(cd("form-data;name=\"a\"")), "no space after ;")
    }

    func testBoundaryPrefixInsideContentIsRefused() {
        // PHP ends the part at "\r\n--fbXYZ" no matter what follows, RFC 2046 reads on: neither reading is guessed
        rejects(file("doc", "a.pdf", pdf + "\r\n--\(b)X not a boundary") + close, "boundary prefix in a file")
        rejects(text("a", "x\r\n--\(b)yz") + close, "boundary prefix in a text part")
        rejects(text("a", "x\n--\(b)yz") + close, "bare-LF boundary line: PHP splits there too")
        rejects(file("doc", "a.pdf", pdf + "\n--\(b)--\r\n") + close, "bare-LF closing line inside a file")
    }

    func testFileAndTextBudgetsStopDuringParsing() {
        let six = (0..<6).map { file("f\($0)") }.joined()
        rejects(six + close, "sixth file", status: .unsupportedMediaType)
        rejects(six, "the sixth file is refused before the rest of the body is even framed", status: .unsupportedMediaType)
        let big = String(repeating: "x", count: MP.maxTextBytes / 2 + 1)
        rejects(text("a", big) + text("b", big) + close, "text budget across parts: 413 like an oversized file", status: .payloadTooLarge)
        XCTAssertNoThrow(try parse(text("a", String(repeating: "x", count: MP.maxTextBytes)) + close))
    }

    /// PHP is the reference for what an SDK body means (contracts/crypto/signatur.md): the canonical JSON the SDK signs must be exactly
    /// what Swift reconstructs from the bytes it receives. Skipped without a `php` binary.
    func testPHPSDKBodiesAreReadExactlyLikePHPBuildsThem() throws {
        let php = try Self.php()
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("sdk/php/src").path
        let script = """
            spl_autoload_register(function ($c) { $f = \(String(reflecting: src)) . '/' . str_replace('\\\\', '/', substr($c, strlen('FormBackend\\\\'))) . '.php'; if (is_file($f)) { require $f; } });
            $cases = [
              [['a' => 'x', 'b' => ['c' => 'ü', 'd' => ['1', '2']], '10' => 'n', 'q"' => "line\\r\\nbreak", 'amp' => 'a&b=c%20'], ['doc' => ['name' => 'r.pdf', 'content' => "%PDF-1.4\\n--x\\r\\n"]]],
              [['empty' => '', 'lead' => ' sp ace '], ['10' => ['name' => 'a.pdf', 'content' => "%PDF-a"], '2' => [['name' => 'b.pdf', 'content' => "%PDF-b"], ['name' => 'c.pdf', 'content' => "%PDF-c"]]]],
            ];
            $out = [];
            foreach ($cases as [$f, $files]) { $r = FormBackend\\Canonical::buildMultipart($f, $files); $out[] = ['body' => base64_encode($r['body']), 'boundary' => $r['boundary'], 'canonical' => $r['canonical']]; }
            echo json_encode($out);
            """
        let p = Process(); p.executableURL = URL(fileURLWithPath: php); p.arguments = ["-r", script]
        let pipe = Pipe(), err = Pipe(); p.standardOutput = pipe; p.standardError = err
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return XCTFail("php cannot run the SDK: \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))") }
        let cases = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(cases.count, 2)
        for c in cases {
            let body = try XCTUnwrap(Data(base64Encoded: c["body"]!))
            let m = try MP.parse(Array(body), boundary: c["boundary"]!)
            let fields = try FormEncodedParser.parse(m.urlencoded)
            let (_, fileFields) = try Uploads.prepare(m.files)
            let canonical = try RequestSignature.canonical(fields: fields, files: fileFields)
            XCTAssertEqual(String(decoding: canonical, as: UTF8.self), c["canonical"])
        }
    }

    /// Differential test against PHP's OWN multipart parser (`php -S`, the reference interpreter of the legacy backend): every body
    /// Swift accepts must mean the same fields, file names and file bytes to PHP. Ambiguous bodies are refused by Swift (tests above).
    func testAcceptedBodiesMeanTheSameToPHPsOwnParser() throws {
        let php = try Self.php()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-diff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("""
            <?php header('Content-Type: application/json'); $f = [];
            foreach ($_FILES as $k => $v) { $f[$k] = [base64_encode($v['name']), $v['error'] === 0 ? base64_encode(file_get_contents($v['tmp_name'])) : 'error ' . $v['error']]; }
            echo json_encode(['post' => $_POST, 'files' => (object)$f]);
            """.utf8).write(to: dir.appendingPathComponent("r.php"))
        let port = Int.random(in: 20000..<40000)
        let server = Process(); server.executableURL = URL(fileURLWithPath: php)
        server.arguments = ["-S", "127.0.0.1:\(port)", dir.appendingPathComponent("r.php").path]
        server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }

        func phpReads(_ body: String) -> [String: Any]? {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!); req.httpMethod = "POST"; req.timeoutInterval = 5
            req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type"); req.httpBody = Data(body.utf8)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var out: [String: Any]?
            URLSession.shared.dataTask(with: req) { d, _, _ in out = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }; done.signal() }.resume()
            _ = done.wait(timeout: .now() + 6)
            return out
        }
        var ready = false
        for _ in 0..<50 where !ready { if phpReads(close) != nil { ready = true } else { Thread.sleep(forTimeInterval: 0.1) } }
        guard ready else { return XCTFail("php -S did not start") }

        let cases = [
            text("a", "1 2") + text("u", "ä&=") + file("doc") + close,
            "--\(b)\r\nContent-Disposition: form-data; name=a\r\n\r\ntoken\r\n" + close,
            "--\(b)\r\nContent-Disposition: form-data;name=\"a\";filename=\"r.pdf\"\r\nContent-Type: application/pdf\r\n\r\n\(pdf)\r\n" + close,
            file("doc", "r.pdf", pdf + "\r\n-\(b)X tail") + text("t", "x\r\n-\(b) --\(b)") + close,
            text("a", "1") + "--\(b)--",
            "--\(b)\r\nContent-Disposition: form-data; name=\"q\\\"x\"\r\n\r\nquoted\r\n" + close,
            file("anlage", "Lebenslauf_Müller_ä.pdf") + text("straße", "Größe") + close,
            file("anlage", "Mu\u{0308}ller.pdf") + close,
        ]
        for (i, body) in cases.enumerated() {
            let m = try MP.parse(Array(body.utf8), boundary: b)
            var swiftPost: [String: String] = [:]
            for pair in String(decoding: m.urlencoded, as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? "?" }
                swiftPost[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
            // file names as base64 of their bytes: Swift's String == treats NFC and NFD as equal, PHP must see the very same bytes
            let swiftFiles = Dictionary(uniqueKeysWithValues: m.files.map { ($0.field, [Data($0.filename.utf8).base64EncodedString(), $0.data.base64EncodedString()]) })
            guard let r = phpReads(body) else { XCTFail("case \(i): no answer from php"); continue }
            XCTAssertEqual(r["post"] as? [String: String] ?? [:], swiftPost, "case \(i): text fields")
            XCTAssertEqual(r["files"] as? [String: [String]] ?? [:], swiftFiles, "case \(i): files")
        }
    }
}
