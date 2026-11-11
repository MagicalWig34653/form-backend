// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Crypto
import SQLKit
import FormCrypto
import FormPersistence

// Explicit projection contract; additional populated columns need human mapping review.
let legacyConfigurationColumns = ["UUID","name","domains","fromName","betreff","betreffToFIller","toProductionMails","toTestingMails","modes","active","outgoingProductionServer","outgoingTestingServer","formularSendMailToFiller","essentialPostFields","mailBodyFiller","mailBody","besondereKategorien"]

extension LegacyRow {
    var hasUnmappedConfigurationValues: Bool {
        let known = Set(legacyConfigurationColumns + ["ID", "cloudflareKeys"])
        return values.contains { key, value in !known.contains(key) && value.map { !$0.isEmpty } == true }
    }
}

extension LegacyImporter {
    func owner(_ p: ImportPlan, _ r: LegacyRow, form: String = "formularUUID") throws -> (String,String) {
        let f = try r.required(form); guard let c = p.formCustomers[f] else { throw ImportFailure.invalidPlan }; return (try uid(c),try r.uuid(form))
    }
    func timestamp(_ text: String?, table: String, column: String) throws -> String {
        guard let text else { return "NULL" }; guard let t = Int64(text), t >= 0, t <= 253402300799 else { throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidTimestamp) }
        return t == 0 ? "NULL" : val(DB.time(Date(timeIntervalSince1970:Double(t))))
    }
    func store(_ db: SQLDatabase, _ p: ImportPlan, customer: String, form: String, submission: String?, role: String, wire: String, encoding: String = "raw") async throws -> Destination {
        let packet = try PackageV2(wire)
        guard try await scalar(db,"SELECT HEX(generation_id) AS v FROM customer_key_generations WHERE customer_id=\(customer) AND kid=\(val(packet.kid))") != nil else { throw ImportFailure.invalidSourceAt(table:"stored_objects",column:"kid",reason:.unknownKeyGeneration) }
        let id = bin(DB.bin(UUID()).data), data = Data(wire.utf8)
        return try await insert(db,"stored_objects",["id":id,"customer_id":customer,"form_id":form,"submission_id":submission ?? "NULL","object_role":val(role),"backend":"'db'","ciphertext":bin(data),"packet_format":"'KUBUS-AEAD:2'","wrap_kind":val(packet.wrap),"kid":val(packet.kid),"content_encoding":val(encoding),"ciphertext_sha256":bin(Data(SHA256.hash(data:data))),"payload_sha256":bin(Data(SHA256.hash(data:packet.iv + packet.ciphertext + packet.tag))),"byte_count":String(data.count),"state":"'ready'"],key:["id":id])
    }
    func transform(_ src: SQLDatabase, _ db: SQLDatabase, _ p: ImportPlan, _ table: String, _ r: LegacyRow) async throws -> [Destination] {
        switch table {
        case "datenschluessel":
            let kid = try r.required("kid")
            guard let customer = p.keyCustomers[kid], p.customers[customer] != nil,
                  let number = p.keyGenerationNumbers[kid], number > 0,
                  let pub = try r.bytes("publicKey"), pub.count == 32, try keyID(pub) == kid,
                  ["aktiv","auslaufend"].contains(try r.required("status")) else { throw ImportFailure.invalidPlan }
            let c = try uid(customer)
            return [try await insert(db,"customer_key_generations",["generation_id":bin(DB.bin(UUID()).data),"customer_id":c,"kid":val(kid),"generation_no":String(number),"public_key":bin(pub),"state":val(try r.required("status") == "aktiv" ? "active":"retiring"),"created_at":try timestamp(r.required("erstelltAm"),table:r.table,column:"erstelltAm")],key:["customer_id":c,"kid":val(kid)])]
        case "datenschluesselRecovery":
            // Legacy recovery envelope (bvk www/src/krypto/schluessel-modell.js recoveryWickeln/kekR, normalisierePassphrase in
            // schluessel-seite.js): PBKDF2-HMAC-SHA256(normalized code, salt[32], 600000) -> AES-256-GCM(iv[12], AAD=ASCII(kid), sk_D) = 48 bytes.
            // Byte-for-byte the format of pwa keys.ts wrapRecovery/openRecovery, so it is copied exactly, never derived or re-wrapped.
            let kid = try r.required("kid")
            guard kid.range(of: "^[0-9a-f]{16}$", options: .regularExpression) != nil,
                  let customer = p.keyCustomers[kid], p.customers[customer] != nil else { throw ImportFailure.invalidPlan }
            let c = try uid(customer)
            // Only for the generation imported for exactly this customer (row from "datenschluessel" in the same run).
            guard try await scalar(db,"SELECT kid AS v FROM customer_key_generations WHERE customer_id=\(c) AND kid=\(val(kid))") == kid else { throw ImportFailure.invalidPlan }
            guard let salt = try r.bytes("salt"), salt.count == 32, let iv = try r.bytes("iv"), iv.count == 12,
                  let wrap = try r.bytes("wrap"), wrap.count == 48, try r.required("iterationen") == "600000" else { throw ImportFailure.invalidSource }
            // A recovery written by the new system for this generation is never replaced.
            guard try await scalar(db,"SELECT kid AS v FROM data_key_recovery WHERE customer_id=\(c) AND kid=\(val(kid))") == nil else { throw ImportFailure.conflict }
            let created = try timestamp(r.required("erstelltAm"),table:r.table,column:"erstelltAm")
            guard created != "NULL" else { throw ImportFailure.invalidSourceAt(table:r.table,column:"erstelltAm",reason:.invalidTimestamp) }
            return [try await insert(db,"data_key_recovery",["customer_id":c,"kid":val(kid),"kdf_name":"'pbkdf2-hmac-sha256'","salt":bin(salt),"iterations":"600000","iv":bin(iv),"wrapped_key":bin(wrap),"created_at":created],key:["customer_id":c,"kid":val(kid)])]
        case "outgoingMailServer", "outgoingMailProxy":
            let id = try r.required("UUID"), idSQL = try r.uuid("UUID")
            guard let owners = p.connectionCustomers[id], !owners.isEmpty else { throw ImportFailure.invalidPlan }
            var safe: [String:String] = [:]
            let keys = table == "outgoingMailServer" ? ["SMTPHost","SMTPPort","SMTPSecurity","SMTPallowSelfSigned","fromMail"] : ["fromMail"]
            for key in keys { safe[key] = try r.text(key) }
            if table == "outgoingMailProxy" { // URLs can contain credentials, paths or queries: keep the entire source URL protected.
                safe["legacyURLProtected"] = "true"
            }
            let credential = table == "outgoingMailServer" ? ["username":try r.text("SMTPUsername"),"password":try r.text("SMTPPassword")] : ["url":try r.text("proxyURL"),"auth":try r.text("proxyAuth")]
            let ref = try await secrets.put(Data(try json(credential).utf8),on:db)
            var refs = [try await insert(db,"connections",["id":idSQL,"kind":val(table == "outgoingMailServer" ? "smtp":"mail-proxy"),"name":val(try r.required("name")),"safe_config_json":val(try json(safe)),"credential_ref":val(ref),"enabled":"0"],key:["id":idSQL])]
            // Secret ciphertext is part of the integrity check as well.
            refs.append(Destination(table:"managed_secrets",predicate:"ref=\(val(ref))"))
            for c in owners { guard p.customers[c] != nil else { throw ImportFailure.invalidPlan }; refs.append(try await insert(db,"customer_connections",["customer_id":try uid(c),"connection_id":idSQL],key:["customer_id":try uid(c),"connection_id":idSQL])) }
            return refs
        case "formulare":
            let (c,f) = try owner(p,r,form:"UUID")
            return [try await insert(db,"forms",["id":f,"customer_id":c,"name":val(try r.text("name")),"active":"0"],key:["id":f])] + (try await configuration(src,db,p,r,customer:c,form:f))
        case "formularFelder":
            let (c,f) = try owner(p,r)
            guard let definition = try await scalar(db,"SELECT definition_json AS v FROM form_versions WHERE customer_id=\(c) AND form_id=\(f) AND version_no=1"),
                  let document = try JSONSerialization.jsonObject(with:Data(definition.utf8)) as? [String:Any],
                  let fields = document["legacyFields"] as? [[String:Any]],
                  let field = fields.first(where: { $0["ID"] as? String == (try? r.required("ID")) }) else { throw ImportFailure.invalidSource }
            var expected: [String:String?] = [:]
            for key in r.values.keys { expected[key] = try r.text(key) }
            // JSONSerialization and JSONEncoder sort mixed-case keys differently.
            // Compare field values (including nulls), not serialized object key order.
            let actual = try JSONDecoder().decode([String:String?].self,from:JSONSerialization.data(withJSONObject:field))
            guard actual == expected else { throw ImportFailure.conflict }
            return [Destination(table:"form_versions",predicate:"form_id=\(f) AND version_no=1")]
        case "anfragen":
            let (c,f) = try owner(p,r), id = try r.uuid("UUID")
            let sub = try await insert(db,"submissions",["id":id,"customer_id":c,"form_id":f,"release_evidence":"'legacy-unknown'","received_at":try timestamp(r.text("time"),table:r.table,column:"time"),"environment":"'legacy-unknown'","state":"'migration-review'","removable":try boolean(r,"removable"),"malware_scan_status":val(try r.text("malwareScanStatus") ?? "nicht_geprueft")],key:["id":id])
            var refs = [sub]
            // Each package is checked independently. Unsupported packages stay in the immutable source dump.
            var review = false
            for (col,role) in [("data","data"),("file1Enc","attachment"),("mailBody","mail-organisation"),("mailBodyFiller","mail-filler")] {
                if let wire = try r.text(col), !wire.isEmpty {
                    if (try? PackageV2(wire)) != nil {
                        do { refs.append(try await store(db,p,customer:c,form:f,submission:id,role:role,wire:wire,encoding:role.hasPrefix("mail-") ? "legacy-base64-trimmed-mail" : (role == "data" ? "legacy-json-force-object":"raw"))) }
                        catch ImportFailure.invalidSource { review = true }
                    } else { review = true }
                }
            }
            if try r.bytes("file1") != nil || r.text("errors") != nil || r.text("sentServer") != nil || r.text("file1Name") != nil { review = true }
            // Preserve the submission even when packages require browser-assisted conversion.
            if review { try await reviewIssue(db,p,table,try r.required("ID"),"unsupported-content") }
            return refs
        case "anfrageIdempotenz":
            let (c,f) = try owner(p,r), raw = Data(try r.required("idempotenzSchluessel").utf8)
            guard (1...190).contains(raw.count) else { throw ImportFailure.invalidSource }
            let id = try r.uuid("anfrageUUID"), digest = bin(Data(SHA256.hash(data:raw)))
            guard try await scalar(db,"SELECT HEX(id) AS v FROM submissions WHERE id=\(id) AND customer_id=\(c) AND form_id=\(f)") != nil else { throw ImportFailure.invalidSource }
            return [try await insert(db,"ingest_idempotency",["customer_id":c,"form_id":f,"key_digest":digest,"legacy_raw_key":bin(raw),"submission_id":id,"environment":"'legacy-unknown'","release_evidence":"'legacy-unknown'","result_state":"'available'","digest_evidence":"'legacy-missing'","state":"'review'","created_at":try timestamp(r.required("createdAt"),table:r.table,column:"createdAt")],key:["customer_id":c,"form_id":f,"key_digest":digest])]
        case "formularWebhooks":
            let (c,f) = try owner(p,r), id = try r.uuid("UUID")
            guard let pub = Data(base64Encoded:try r.required("ed25519OeffentlicherSchluessel")), pub.count == 32,
                  let priv = Data(base64Encoded:try r.required("ed25519PrivatSchluessel")), priv.count == 64,
                  let url = URL(string:try r.required("zielUrl")), url.scheme == "https", url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw ImportFailure.invalidSource }
            guard let signer = try? Curve25519.Signing.PrivateKey(rawRepresentation:priv.prefix(32)),
                  signer.publicKey.rawRepresentation == pub, priv.suffix(32) == pub else { throw ImportFailure.invalidSource }
            let ref = try await secrets.put(priv,on:db)
            return [try await insert(db,"webhook_endpoints",["id":id,"customer_id":c,"form_id":f,"target_url":val(url.absoluteString),"signing_secret_ref":val(ref),"public_key":bin(pub),"active":"0","created_at":val(try r.required("erstelltAm"))],key:["id":id]), Destination(table:"managed_secrets",predicate:"ref=\(val(ref))")]
        case "statistics":
            guard let review = p.statisticsReview, !review.isEmpty else { throw ImportFailure.invalidPlan }
            let (c,f) = try owner(p,r); var refs: [Destination] = []; var metadata: [String:String?] = [:]
            for key in r.values.keys where !["ID","UUID","formularUUID","timestamp","status","type"].contains(key) { metadata[key] = try r.text(key) }
            let customer = try r.required("formularUUID"); guard let cid = p.formCustomers[customer], let pk = p.statisticsPublicKeys[cid], let pub = Data(base64Encoded:pk), pub.count == 32 else { throw ImportFailure.invalidPlan }
            let wire = try PackageV2.seal(Data(try json(metadata).utf8),recipient:pub).wire
            let object = try await store(db,p,customer:c,form:f,submission:nil,role:"statistics-metadata",wire:wire); refs.append(object)
            let objectID = String(object.predicate.dropFirst("`id`=".count))
            refs.append(try await insert(db,"legacy_statistics",["source_namespace":val(p.namespace),"source_id":try integer(r.required("ID"),table:r.table,column:"ID"),"legacy_uuid":try r.uuid("UUID"),"customer_id":c,"form_id":f,"occurred_at":val(try r.required("timestamp")),"legacy_status":val(try r.required("status")),"legacy_type":val(try r.text("type")),"metadata_object_id":objectID,"has_gclid":try present(r,"gclid"),"has_user_agent":try present(r,"userAgent"),"has_ip_reference":metadata.values.contains { value in value.flatMap { $0 }?.range(of:"(?:[0-9]{1,3}\\.){3}[0-9]{1,3}|[0-9a-fA-F]{0,4}:[0-9a-fA-F:]+",options:.regularExpression) != nil } ? "1":"0"],key:["source_namespace":val(p.namespace),"source_id":try integer(r.required("ID"),table:r.table,column:"ID")]))
            return refs
        default: throw ImportFailure.invalidSource
        }
    }
    func integer(_ s: String, table: String, column: String) throws -> String { guard let n = Int64(s), n >= 0 else { throw ImportFailure.invalidSourceAt(table:table,column:column,reason:.invalidInteger) }; return String(n) }
    func boolean(_ r: LegacyRow, _ k: String) throws -> String { let s = try r.required(k); guard ["0","1"].contains(s) else { throw ImportFailure.invalidSourceAt(table:r.table,column:k,reason:.invalidBoolean) }; return s }
    func present(_ r: LegacyRow, _ k: String) throws -> String { try r.text(k).map { $0.isEmpty ? "0":"1" } ?? "0" }
    func configuration(_ src: SQLDatabase, _ db: SQLDatabase, _ p: ImportPlan, _ r: LegacyRow, customer: String, form: String) async throws -> [Destination] {
        var safe: [String:String?] = [:]
        for key in legacyConfigurationColumns { safe[key] = try r.text(key) }
        // Legacy configuration remains an explicit, non-runtime draft projection until converted/reviewed.
        var secretRefs: [Destination] = []
        if let secret = try r.text("cloudflareKeys"), !secret.isEmpty {
            let ref = try await secrets.put(Data(secret.utf8),on:db)
            safe["cloudflareSecretRef"] = ref
            secretRefs.append(Destination(table:"managed_secrets",predicate:"ref=\(val(ref))"))
        }
        let cols = try await columns(src,"formularFelder")
        let projection = try await projection(src,"formularFelder",cols)
        let rows = try await src.raw(query("SELECT \(projection) AS v FROM formularFelder WHERE formularUUID=\(val(try r.required("UUID"))) ORDER BY reihenfolge,ID")).all(decoding:TextRow.self)
        var fields: [[String:String?]] = []
        for row in rows {
            let field = try LegacyRow.decode(row.v,table:"formularFelder")
            var values: [String:String?] = [:]
            for key in cols { values[key] = try field.text(key) }
            fields.append(values)
        }
        let definition = "{\"legacyConfiguration\":" + (try json(safe)) + ",\"legacyFields\":" + (try json(fields)) + "}"
        let definitionRef = try await insert(db,"form_versions",["customer_id":customer,"form_id":form,"version_no":"1","contract_version":"'migration-review'","definition_json":val(definition),"definition_sha256":bin(Data(SHA256.hash(data:Data(definition.utf8)))),"encryption_profile":"'hpke-v2'","validation_profile":"'legacy-v1'","legacy_adapter_ref":"'inactive:migration-review'","special_categories":try boolean(r,"besondereKategorien"),"storage_backend":"'db'","max_upload_bytes":"10485760","created_at":"'1970-01-01 00:00:00'"],key:["form_id":form,"version_no":"1"])
        return [definitionRef] + secretRefs
    }

    func reviewIssue(_ db: SQLDatabase, _ p: ImportPlan, _ table: String, _ key: String, _ code: String) async throws {
        // Run id is resolved from the immutable plan, avoiding any plaintext content in diagnostics.
        let mapping = bin(Data(SHA256.hash(data:Data(try json(p).utf8))))
        try await exec(db,"INSERT INTO migration_issues (id,run_id,source_table,source_key,issue_code,state,reported_at) SELECT \(bin(DB.bin(UUID()).data)),id,\(val(table)),\(bin(Data(key.utf8))),\(val(code)),'open',UTC_TIMESTAMP(6) FROM migration_runs WHERE source_namespace=\(val(p.namespace)) AND dump_sha256=\(bin(try unhex(p.dumpSHA256))) AND mapping_sha256=\(mapping) AND importer_version='p9-1' ON DUPLICATE KEY UPDATE issue_code=issue_code")
    }
}
