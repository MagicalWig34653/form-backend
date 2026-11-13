// SPDX-License-Identifier: AGPL-3.0-only
@testable import FormAdmin
import Crypto
import FormAuth
import FormCore
import FormCrypto
import FormMigration
import FormPersistence
import Foundation
import Logging
import SQLKit
import XCTest
import XCTVapor

/// Synthetic legacy source for the import rehearsal: the real legacy schema (`legacy-real.sql`, baseline plus legacy migrations
/// 001-040) in a throw-away MariaDB schema, a read-only reader, deterministic keys and realistic content. Synthetic data only.
struct RehearsalSource {
    // Deterministic identities (the PWA golden file under contracts/migration depends on them).
    static let alpha = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let formA = "11111111-1111-4111-8111-111111111111", formB = "22222222-2222-4222-8222-222222222222", formC = "33333333-3333-4333-8333-333333333333"
    static let smtpA = "44444444-4444-4444-8444-444444444441", smtpTest = "44444444-4444-4444-8444-444444444442", proxy = "44444444-4444-4444-8444-444444444443"
    static let smtpPassword = "SMTP-Passwort-Geheim-4711", proxyURL = "https://proxyuser:proxy-secret-99@proxy.example.invalid/send"
    static let cloudflare = "cf-secret-key-123"
    static let recoveryPassphrase = "recovery-code-nur-im-test"
    /// Synthetic legacy recovery code of the active key (the envelope in `datenschluesselRecovery` is sealed under it).
    static let recoveryWrap = try! Data(hex: "1818a17eeba88a06a5c09c538a539f0463322de3f93adb2306ae6304eeddd183f8fee562537397dd2c07fcea52c5e3da")
    static let recoveryCode = "SYNT-8K2M-Q7WX-4PDN-ZB6V-H3JR-9TLC-5EFA"

    static func privateKey(_ seed: UInt8) -> Curve25519.KeyAgreement.PrivateKey { try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)) }
    // The legacy system has exactly one active data key for the whole installation (plus retiring ones); every form uses it.
    static let alphaOld = privateKey(0x10), alphaActive = privateKey(0x11)
    static func kid(_ key: Curve25519.KeyAgreement.PrivateKey) -> String { try! keyID(key.publicKey.rawRepresentation) }

    /// What one submission was given, for the byte-for-byte and round-trip checks.
    struct Expected {
        var uuid: String
        var packages: [String: (wire: String, plain: Data?, key: Curve25519.KeyAgreement.PrivateKey?)] = [:]   // role -> package
        var reviewCause: String?
    }

    let name: String, reader: String, password: String
    var expected: [String: Expected] = [:]
    var submissionCount = 0

    static func seal(_ plain: Data, _ key: Curve25519.KeyAgreement.PrivateKey) -> String { try! PackageV2.seal(plain, recipient: key.publicKey.rawRepresentation).wire }

    /// A `sym` wrapped package as the legacy system writes it after re-wrapping (kubus-langzeit v1 KEK from sk_D).
    static func sealSym(_ plain: Data, _ key: Curve25519.KeyAgreement.PrivateKey) -> String {
        let cek = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let kek = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.rawRepresentation), salt: Data(), info: Data("kubus-langzeit v1".utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        let kid = Self.kid(key)
        let wrapNonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) }), nonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })
        let wrapped = try! AES.GCM.seal(cek, using: SymmetricKey(data: kek), nonce: AES.GCM.Nonce(data: wrapNonce), authenticating: Data(kid.utf8))
        let payload = try! AES.GCM.seal(plain, using: SymmetricKey(data: cek), nonce: AES.GCM.Nonce(data: nonce), authenticating: Data("KUBUS-AEAD:2".utf8))
        return "KUBUS-AEAD:2|\(kid)|sym|\(wrapNonce.base64EncodedString()):\((wrapped.ciphertext + wrapped.tag).base64EncodedString())|\(nonce.base64EncodedString())|\(payload.ciphertext.base64EncodedString())|\(payload.tag.base64EncodedString())"
    }

    static func uuid(_ n: Int) -> String { String(format: "cccccccc-0000-4000-8000-%012d", n) }

    struct D: Decodable { let d: String }
    /// Runs `body` on one pooled connection switched to the source schema and back (the pool is shared).
    static func on<T>(_ fx: AdminFixture, _ schema: String, _ body: @escaping (SQLDatabase) async throws -> T) async throws -> T {
        try await fx.sql.withSession { s in
            let original = try await s.raw("SELECT DATABASE() AS d").first(decoding: D.self)!.d
            try await s.raw("USE \(ident: schema)").run()
            do { let r = try await body(s); try await s.raw("USE \(ident: original)").run(); return r }
            catch { try? await s.raw("USE \(ident: original)").run(); throw error }
        }
    }
    func on<T>(_ fx: AdminFixture, _ body: @escaping (SQLDatabase) async throws -> T) async throws -> T { try await Self.on(fx, name, body) }

    /// Schema, users and content. `submissions` is the number of generated realistic rows per form besides the special cases.
    static func create(_ fx: AdminFixture, perForm: Int = 8, statistics: Int = 6) async throws -> RehearsalSource {
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
        var source = RehearsalSource(name: "rehearsal_src_" + suffix, reader: "reh_r_" + suffix, password: "Quell-Passwort-" + suffix)
        try await fx.sql.raw("CREATE DATABASE \(ident: source.name)").run()
        try await fx.sql.raw(SQLQueryString("CREATE USER '\(source.reader)'@'%' IDENTIFIED BY '\(source.password)'")).run()
        try await fx.sql.raw(SQLQueryString("GRANT SELECT ON `\(source.name)`.* TO '\(source.reader)'@'%'")).run()
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let schema = try String(contentsOf: tests.appendingPathComponent("FormMigrationTests/Fixtures/legacy-real.sql"), encoding: .utf8)
        var expected: [String: Expected] = [:]
        let count = try await source.on(fx) { s in
            // The dump lists tables alphabetically, foreign keys may point at tables created later.
            try await s.raw("SET FOREIGN_KEY_CHECKS=0").run()
            for statement in try SQLStatementSplitter.split(schema) { try await s.raw(SQLQueryString(statement)).run() }
            try await s.raw("SET FOREIGN_KEY_CHECKS=1").run()
            try await populate(s, perForm: perForm, statistics: statistics, expected: &expected)
            struct N: Decodable { let n: Int }
            return try await s.raw("SELECT COUNT(*) AS n FROM anfragen").first(decoding: N.self)!.n
        }
        source.expected = expected; source.submissionCount = count
        return source
    }

    func drop(_ fx: AdminFixture) async {
        try? await fx.sql.raw(SQLQueryString("DROP USER IF EXISTS '\(reader)'@'%'")).run()
        try? await fx.sql.raw("DROP DATABASE IF EXISTS \(ident: name)").run()
    }

    static func populate(_ s: SQLDatabase, perForm: Int, statistics: Int, expected: inout [String: Expected]) async throws {
        let creator = "99999999-9999-4999-8999-999999999999"
        // Keys: rotated once (the old key is still needed for old submissions).
        for (key, status, created) in [(alphaOld, "auslaufend", 1_700_000_000), (alphaActive, "aktiv", 1_750_000_000)] as [(Curve25519.KeyAgreement.PrivateKey, String, Int)] {
            try await s.raw("INSERT INTO datenschluessel (kid,publicKey,status,erstelltAm,erstelltVon) VALUES (\(bind: kid(key)),\(bind: Blob(key.publicKey.rawRepresentation)),\(bind: status),\(bind: created),\(bind: creator))").run()
        }
        // Recovery envelopes exist for the active generations (bytes opaque for the importer; copied exactly).
        for key in [alphaActive] {
            // A real legacy recovery envelope (PBKDF2-HMAC-SHA256, 600000 iterations, AES-256-GCM with the kid as AAD) of the active key's
            // secret under the synthetic `recoveryCode`; precomputed so that the rehearsals stay fast. The browser E2E opens it.
            let salt = try! Data(hex: "0b121920272e353c434a51585f666d747b828990979ea5acb3bac1c8cfd6dde4"), iv = try! Data(hex: "030405060708090a0b0c0d0e")
            let wrap = recoveryWrap
            try await s.raw("INSERT INTO datenschluesselRecovery (kid,salt,iterationen,iv,wrap,erstelltAm) VALUES (\(bind: kid(key)),\(bind: Blob(salt)),600000,\(bind: Blob(iv)),\(bind: Blob(wrap)),1750000001)").run()
        }
        // Mail connections (credentials only here and later in the encrypted secret store).
        try await s.raw("INSERT INTO outgoingMailServer (UUID,name,SMTPHost,SMTPPort,SMTPSecurity,SMTPUsername,SMTPPassword,SMTPallowSelfSigned,fromMail) VALUES (\(bind: smtpA),'SMTP Müller (Produktion)','smtp.example.invalid','587','tls','mailer@example.invalid',\(bind: smtpPassword),0,'formular@example.invalid')").run()
        try await s.raw("INSERT INTO outgoingMailServer (UUID,name,SMTPHost,SMTPPort,SMTPSecurity,SMTPUsername,SMTPPassword,SMTPallowSelfSigned,fromMail) VALUES (\(bind: smtpTest),'SMTP Test','smtp-test.example.invalid','25','none',NULL,NULL,1,'test@example.invalid')").run()
        try await s.raw("INSERT INTO outgoingMailProxy (UUID,name,proxyURL,proxyAuth,fromMail) VALUES (\(bind: proxy),'Mail-Proxy Büro',\(bind: proxyURL),'Bearer proxy-token-xyz','proxy@example.invalid')").run()
        // Forms: umlauts and emoji in names, a form without a name, a Beta form.
        let formRows: [(String, String?, String?, String?)] = [
            (formA, "Kontaktformular Müller & Söhne 🚀", smtpA, smtpTest), (formB, nil, proxy, nil), (formC, "Newsletter-Anmeldung „Größe“", smtpTest, nil)]
        for (id, name, prod, test) in formRows {
            try await s.raw("""
                INSERT INTO formulare (UUID,name,domains,fromName,betreff,betreffToFIller,toProductionMails,toTestingMails,modes,active,cloudflareKeys,outgoingProductionServer,outgoingTestingServer,formularSendMailToFiller,essentialPostFields,mailBodyFiller,mailBody,besondereKategorien)
                VALUES (\(bind: id),\(bind: name),'example.invalid,www.example.invalid','Büro','Neue Anfrage: {name}','Ihre Anfrage','büro@example.invalid','test@example.invalid','production',1,\(bind: cloudflare),\(bind: prod),\(bind: test),1,'name,email','<p>Danke, {name} 👋</p>','<p>Neue Nachricht von {name}</p>',\(bind: id == formA ? 1 : 0))
                """).run()
        }
        for (form, fields) in [(formA, [("name", "text", 1), ("email", "email", 1), ("nachricht", "text", 0), ("anhang", "datei", 0)]), (formB, [("name", "text", 1), ("telefon", "text", 0)]), (formC, [("email", "email", 1)])] {
            for (index, field) in fields.enumerated() {
                try await s.raw("INSERT INTO formularFelder (formularUUID,feldName,typ,pflicht,regel,reihenfolge) VALUES (\(bind: form),\(bind: field.0),\(bind: field.1),\(bind: field.2),\(bind: index == 1 ? "^[^@]+@[^@]+$" : nil as String?),\(bind: index))").run()
            }
        }
        // Webhook with a real Ed25519 pair (private = seed || public, as the legacy system stores it).
        let signer = Curve25519.Signing.PrivateKey(), pub = signer.publicKey.rawRepresentation
        try await s.raw("INSERT INTO formularWebhooks (UUID,formularUUID,zielUrl,aktiv,ed25519PrivatSchluessel,ed25519OeffentlicherSchluessel,erstelltAm) VALUES (UUID(),\(bind: formA),'https://hooks.example.invalid/in',1,\(bind: (signer.rawRepresentation + pub).base64EncodedString()),\(bind: pub.base64EncodedString()),'2026-01-02 03:04:05')").run()

        // Submissions: older rows under the retired generation, newer under the active one.
        var n = 0
        func add(_ form: String, _ key: Curve25519.KeyAgreement.PrivateKey, time: Int?, data: String?, file: String? = nil, fileName: String? = nil,
                 mailBody: String? = nil, mailFiller: String? = nil, scan: String = "kein_upload", errors: String? = nil, sent: String? = RehearsalSource.smtpA,
                 raw: Data? = nil, cause: String? = nil, packages: [(String, String, Data?, Curve25519.KeyAgreement.PrivateKey?)] = []) async throws {
            n += 1
            let id = uuid(n)
            try await s.raw("""
                INSERT INTO anfragen (UUID,time,formularUUID,sentServer,data,file1,file1Enc,file1Name,malwareScanStatus,errors,mailBody,mailBodyFiller,removable)
                VALUES (\(bind: id),\(bind: time),\(bind: form),\(bind: sent),\(bind: data),\(bind: raw.map { Blob($0) }),\(bind: file),\(bind: fileName),\(bind: scan),\(bind: errors),\(bind: mailBody),\(bind: mailFiller),\(bind: n % 3 == 0 ? 0 : 1))
                """).run()
            var item = Expected(uuid: id, reviewCause: cause ?? (fileName != nil ? "file1Name" : nil))
            for (role, wire, plain, k) in packages { item.packages[role] = (wire, plain, k) }
            expected[id] = item
        }
        func plain(_ i: Int, _ form: String) -> Data {
            Data(#"{"name":"Jörg Müßig \#(i)","email":"joerg\#(i)@example.invalid","nachricht":"Grüße 👋🏽 — Ärger mit Öl & Äpfeln\n\tZeile 2 \"zitiert\" \\ Pfad","leer":"","form":"\#(form)","marker":"KLARTEXT-MARKER-\#(i)"}"#.utf8)
        }
        for (form, oldKey, newKey) in [(formA, alphaOld, alphaActive), (formB, alphaOld, alphaActive), (formC, alphaOld, alphaActive)] {
            for i in 1...perForm {
                let key = i <= perForm / 2 ? oldKey : newKey
                let p = plain(n + 1, form)
                let data = i % 4 == 0 ? sealSym(p, key) : seal(p, key)
                var packages: [(String, String, Data?, Curve25519.KeyAgreement.PrivateKey?)] = [("data", data, p, key)]
                var mail: String?, filler: String?, file: String?, fileName: String?
                if i % 2 == 0 {
                    let body = Data("<html><body>Hallo Büro, Anfrage \(n + 1) KLARTEXT-MARKER-MAIL</body></html>".utf8)
                    mail = seal(body, key); packages.append(("mail-organisation", mail!, body, key))
                    let fill = Data("<p>Danke für Ihre Anfrage 🙏</p>".utf8)
                    filler = seal(fill, key); packages.append(("mail-filler", filler!, fill, key))
                }
                if i % 3 == 0 {
                    let blob = Data((0..<(40_000 + i * 1000)).map { UInt8(($0 &* 31 &+ i) & 0xff) })
                    file = seal(blob, key); fileName = "Anhang-\(i).pdf"; packages.append(("attachment", file!, blob, key))
                }
                try await add(form, key, time: 1_700_000_000 + n * 3600, data: data, file: file, fileName: fileName, mailBody: mail, mailFiller: filler,
                              scan: file == nil ? "kein_upload" : "sauber", packages: packages)
            }
        }
        // Special cases. NULL / empty fields, no time, a form without any package, and a large attachment (3 MB plaintext).
        try await add(formA, alphaActive, time: nil, data: nil)
        try await add(formA, alphaActive, time: 0, data: "", file: "", mailBody: "")
        let big = Data((0..<3_000_000).map { UInt8(($0 &* 131 &+ 7) & 0xff) })
        let bigWire = seal(big, alphaActive), bigData = plain(n + 1, formA)
        let bigDataWire = seal(bigData, alphaActive)
        try await add(formA, alphaActive, time: 1_760_000_000, data: bigDataWire, file: bigWire, fileName: "Gross.bin", scan: "sauber",
                      packages: [("data", bigDataWire, bigData, alphaActive), ("attachment", bigWire, big, alphaActive)])
        // Packages the importer cannot take over stay an examination case (never an abort): defective header, old format, plaintext
        // attachment bytes, error text and sent server (unsupported-content review).
        let broken = "KUBUS-AEAD:2|" + kid(alphaActive) + "|hpke|nicht-base64!|x|y|z"
        try await add(formA, alphaActive, time: 1_760_000_100, data: broken, cause: "unsupported-content")
        try await add(formB, alphaActive, time: 1_760_000_200, data: "Zm9v:YmFy:YmF6", cause: "unsupported-content")
        let validData = plain(n + 1, formB), validWire = seal(validData, alphaActive)
        try await add(formB, alphaActive, time: 1_760_000_300, data: validWire, errors: "Zustellung fehlgeschlagen: 451", sent: "smtp.example.invalid", raw: Data([0, 1, 2, 255]), cause: "unsupported-content",
                      packages: [("data", validWire, validData, alphaActive)])
        // Idempotency keys for a few submissions.
        for i in 1...3 {
            try await s.raw("INSERT INTO anfrageIdempotenz (formularUUID,idempotenzSchluessel,anfrageUUID,createdAt) VALUES (\(bind: formA),\(bind: "retry-ü-\(i)"),\(bind: uuid(i)),\(bind: 1_700_000_000 + i))").run()
        }
        // Statistics (visits and requests).
        if statistics > 0 {
            try await s.raw("INSERT INTO statistics (UUID,timestamp,formularUUID,status,type,gclid,userAgent,domain) SELECT UUID(),'2026-05-05 10:00:00',\(bind: formA),'SUCCESS','VISIT',NULL,'Mozilla/5.0','example.invalid' FROM seq_1_to_\(unsafeRaw: String(statistics))").run()
        }
        // Rows of tables the importer does not map (real legacy data exists there): users and key log.
        try await s.raw("INSERT INTO users (username,password,userType,aktiv,erstelltAm) VALUES ('altbenutzer','$2y$10$synthetischer.hash.nur.fuer.den.test','admin',1,1700000000)").run()
        try await s.raw("INSERT INTO config (name,value,manageable) VALUES ('mail.retry','3',1)").run()
    }
}
