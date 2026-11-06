# P5-B Vertragsergänzung E1–E8

Stand: 30.10.2026. SPDX-License-Identifier: AGPL-3.0-only.
Grundlage: ADR 0007 (Nr. 1–4), `docs/handoffs/P5-B-paket.md`. Kennzeichnung je Punkt:
**ABGELEITET** (aus beschlossenen ADR/Verträgen zwingend), **VORGESCHLAGEN** (Architekturvorschlag, noch
nicht Nutzerbeschluss), **FRAGE Fn** (nicht entscheidbar, siehe `docs/handoffs/P5-B-vertrag-offen.md`).
Dieses Dokument ändert keine beschlossene Entscheidung; es ergänzt `anmeldung.md`, `rechte.md`, die OpenAPI und
`../data/schema-entwurf.sql`.

## E1 Entwurfsspeicher (ABGELEITET aus ADR 0007 Nr. 3; Details VORGESCHLAGEN)
- Tabelle `form_drafts` (`../data/schema-entwurf.sql`, identisch in `backend/db/schema-p3.sql`). Abbildung auf
  `Draft`: `id`, `revision`, `hash` = Hex von `document_sha256`, `document` = `document_json`. ETag = `"<revision>"`.
- `updateDraft`: unter Zeilensperre `UPDATE ... WHERE id=? AND revision=?` (If-Match); fehlender Header 428,
  veraltete Revision 412, ungültiges `DraftDocument` 422. Erfolg setzt `revision+1`, neuen Hash, `updated_*`.
  `PATCH` ersetzt das ganze Dokument (OpenAPI). Der Hash wird immer serverseitig berechnet (E5).
- `createDraft` mit `baseReleaseId`: Dokument wird aus dem Release rekonstruiert (`form_versions.definition_json`,
  `workflow_versions.graph_json`, `release_views` + `view_versions.definition_json`); Release muss zu Kunde/Form
  gehören (sonst 404). Ohne `baseReleaseId`: **FRAGE F2** (Ausgangsdokument).
- Entwurfstabellen berühren `current_release_id` nie. `publication_confirmations` hat jetzt einen zusammengesetzten
  FK auf `form_drafts`. Nur Admin schreibt Entwürfe (ADR 0007 Nr. 1): wird ausschließlich über Rechtevergabe
  (`draft.write` im Admin-Scope) erreicht, nicht über Rollennamen; kein Sonderpfad im Code.

## E2 Passkey-Übernahme (Vertragsteil ABGELEITET; Codeablage: Koordinationsfrage F9)
- Verifikation: eigene swift-crypto-Logik gemäß ADR 0006 Nr. 12 / `docs/handoffs/P3-C.md` (ES256, RS256, EdDSA;
  `pem-spki`; strikte Origin; Zählerregel; UserHandle exakt gegen `passkeys.user_handle` und Konto der Credential-ID).
- Challenge: 32 Zufallsbytes, `auth_challenges` (`passkey-login`, an anonyme Sitzung gebunden, `account_id` NULL,
  nur SHA-256 gespeichert, ≤120 s); Verbrauch (`consumed_at`) bei jedem Prüfversuch, auch bei Prüffehler, in eigener
  committeter Transaktion vor der Prüfung (Rollback der Prüfung darf ihn nicht zurücknehmen).
- Discoverable Login: `allowCredentials` leer, `userVerification=required`, `rpId` und Origin aus fester Konfiguration
  (nie aus Host/Forwarded, `anmeldung.md`). `WebAuthnOptions.publicKey` VORGESCHLAGEN: `{challenge, rpId, timeout,
  userVerification, allowCredentials: []}` (base64url ohne Padding). `WebAuthnResponse.credential` VORGESCHLAGEN:
  `{id, rawId, type:"public-key", response:{authenticatorData, clientDataJSON, signature, userHandle}}`, alles
  base64url; `id` muss `rawId` entsprechen; Größenlimit Body 16 KiB (413).
- Zähler: bedingtes UPDATE `sign_count < neu OR (sign_count=0 AND neu=0)`; Zähleranomalie = Fehlschlag (E4, Audit).
- Nicht Teil: Registrierung (CBOR/COSE). Tests: nur synthetische Vektoren (`backend/poc-passkey/.../vectors.json`);
  Challenge im Test per Zeile mit `SHA256(vector.challenge)` einspielen.

## E3 Login-Abschluss mit zweitem Faktor (ADR 0007 Nr. 2: Pflicht in P5-B)
Operationen: `getSession` (zwingend: liefert CSRF und erzeugt anonyme Sitzung; jede Mutation braucht CSRF), `passkeyOptions`,
`passkeyVerify`, `verifySecondFactorPassword` (nur `method=password`, an Konto der `factor_pending`-Sitzung gebunden).
- ABGELEITET (`anmeldung.md`): `passkeyVerify` ok → Sitzung rotieren, Zustand `factor_pending` (Cookie neu, CSRF neu,
  alte Zeile `revoked`/`replaced_by`, offene Challenges widerrufen). Zweiter Faktor ok → erneut rotieren,
  `authenticated`, `auth_method`, `authenticated_at`, `rights_version`. Zwischensitzung absolut 5 min, Authentifizierte
  Sitzung idle 30 min/absolut 12 h. Zweitfaktor-Fehler: Throttle-Scope `totp` (5/15 min je Konto und IP, dann 15 min).
- VORGESCHLAGEN, fail-closed: **Netzausnahme wird in P5-B nicht implementiert**; der zweite Faktor ist immer
  verlangt (strenger als der Vertrag, kein Lockout-Risiko). Gründe: Vertrauensliste und Client-IP-Ermittlung sind
  OFFEN (`domains-proxy.md`; `X-Forwarded-For` ist dort ausgeschlossen). **FRAGE F6.**
- Cookie: `__Host-admin_session`, Secure/HttpOnly/SameSite=Lax/Path=/ werden **unabhängig von Anfrageheadern** immer
  gesetzt; Cookiewert = zufälliges 256-Bit-Token, `sessions.token_hash = SHA-256(Token)`. Hinter dem Proxy gilt
  `domains-proxy.md` (nur vertrauter Peer, `X-Forwarded-Proto=https`). Die Peer-Liste ist OFFEN; B1 liest sie aus
  Konfiguration, Testmodus muss explizit sein. CSRF: `sessions.csrf_secret_ciphertext` braucht einen Serverschlüssel;
  Secretprovider ist OFFEN (ADR 0005 D9): **FRAGE F5.**
- Passwortprüfung (zweiter Faktor): Format der Bestandshashes und Prüfbibliothek in Swift sind nicht belegt
  (`anmeldung.md`: Argon2id Ziel, Parameter nach Messung): **FRAGE F4.**

## E4 Fehlerhülle und `authentication_failed` (ABGELEITET aus OpenAPI-`Problem`, F9/R2; Codes VORGESCHLAGEN)
- Admin-Routen antworten mit `application/problem+json` und dem Schema `Problem {code, message, requestId}`; der
  Ingest-Vertrag behält sein eigenes Format. Die gemeinsame `ProblemMiddleware` muss pro Routengruppe beide Formen
  liefern (Koordinationsaufgabe, nicht B1/B2).
- Codes (VORGESCHLAGEN): `bad_request` 400, `unauthenticated` 401 (keine/zu schwache Sitzung, `factor_pending`),
  `authentication_failed` 401, `forbidden` 403, `csrf_invalid` 403, `not_found` 404, `conflict` 409,
  `confirmation_expired` 410, `precondition_failed` 412, `precondition_required` 428, `payload_too_large` 413,
  `validation_failed` 422, `rate_limited` 429, `unavailable` 503.
- `authentication_failed`: **jeder** Prüffehler in `passkeyOptions`-Folgeanfrage/`passkeyVerify`/Zweitfaktor
  (Challenge ungültig/abgelaufen/verbraucht/falsche Sitzung, unbekannte Credential, Signatur, Origin, RP-ID-Hash,
  UP/UV, UserHandle, Zähler, falsches Passwort) liefert Status 401, `code=authentication_failed`, festen deutschen
  Text, gleiche Header (`Cache-Control: no-store`, `Content-Type`), kein `Retry-After`, kein `Set-Cookie`; einzig
  `requestId` (Body) und `X-Request-Id` (Header) variieren. Ursache nur im Audit-Event (interner Grund, kein Secret).
  Genau ein Übersetzungspunkt im Code. Fehlendes/ungültiges CSRF bleibt 403 `csrf_invalid` und zählt nicht als Fehlversuch.
- 429: `Retry-After` (ganze Sekunden ≥1) laut OpenAPI. Damit 429 kein Existenzorakel ist, laufen Sperrzähler auch für
  unbekannte Credential-IDs über pseudonymisierte HMAC-Schlüssel (`auth_throttles.subject_hmac`) und Limits vor
  Kontoauflösung (IP, Route) liefern 429 gleichermaßen; Kontosperre eines bekannten Kontos darf nicht anders
  antworten als dieselbe Last auf unbekannter ID. HMAC-Schlüsselquelle: F5.
- Abgelaufene Bestätigung: **410** (OpenAPI `E410`), nicht 409; 409 bleibt für verbraucht, falsche Sitzung/Hash/Revision,
  Idempotenzkonflikt. (Korrigiert die Formulierung in P5-B-paket.md.)

## E5 Kanonisierung und Hash (VORGESCHLAGEN, **FRAGE F1**)
Vorhandene Beispiele nutzen nur eine Fixturekonvention (`contracts/flow/validate.py`, "not a production
canonicalization"); das Verfahren ist damit nicht beschlossen. Vorschlag: JSON Canonicalization Scheme (RFC 8785) über
das jeweilige JSON-Objekt, danach SHA-256, Hex klein (`^[a-f0-9]{64}$`); Zahlen nur als ganze Zahlen im sicheren
Bereich (±2^53−1), keine Gleitkommawerte, keine doppelten Schlüssel, UTF-8 NFC unverändert (keine Normalisierung).
Anwendung: `form_drafts.document_sha256`/`Draft.hash` über das gesamte `DraftDocument`; `definition_sha256` über
`document.form`, `view_versions.definition_sha256` je View, `graph_sha256` über `document.flow`, `manifest_sha256` über
das Abhängigkeitsmanifest. `candidate_sha256` der Bestätigung = Hash des Entwurfs (E7: ohne externe Module ist der
Kandidat das Dokument). Bei späterer Modulauflösung ist eine neue Hashdefinition mit Version nötig. Unabhängig vom
Algorithmus gilt: der Client-Hash dient nur zum Abgleich, maßgeblich ist der unter Sperre neu berechnete Stand (409 bei Abweichung).

## E6 Rechtekatalog und Rechteprüfung (ABGELEITET)
- Seed: `permission_catalog` wird vom Schema selbst befüllt (29 Einträge, `schema-entwurf.sql`; geprüft in
  `backend/db/check.sh`). Die Anwendung schreibt den Katalog nie; beim Start vergleicht sie ihre einkompilierte Menge
  mit der Tabelle und startet bei Abweichung nicht. Tests fügen keine Katalogzeilen ein.
- Effektive Rechte je Anfrage live aus DB (`accounts.active`, `permission_assignments` mit `revoked_at IS NULL`,
  `permission_groups.revoked_at IS NULL`, `permission_group_rights`): Vereinigung aus Direkt- und Gruppengrants,
  Gruppenzuweisung = Schnittmenge Gruppen-/Zuweisungsscope (`rechte.md`). Scope deckt Ziel: `system` alles; `customer`
  ohne `form_id` alle Formulare des Kunden; sonst genau dieses Formular. `form_access`/`customer_memberships` gewähren
  nichts. `sessions.rights_version` ist Momentaufnahme; Abweichung zu `accounts.rights_version` ist kein Fehler, die
  Live-Prüfung entscheidet.
- 404/403 (VORGESCHLAGEN, F7): 404, wenn Ressource nicht existiert oder kein wirksamer Grant des Kontos sie überdeckt;
  403, wenn überdeckt, aber Aktionsrecht fehlt.
- Testdaten: ausschließlich synthetische SQL-Fixtures (Kunde, Konto, Passkey, Grants); keine Bootstrap-API, kein
  Seedpfad im Produktivcode. Erstanlage des ersten Admins ist nicht Teil von P5-B (Migration/Betrieb).

## E7 Release-Umfang P5 (ABGELEITET wo vermerkt, sonst VORGESCHLAGEN)
- Atomare Transaktion `publishRelease` (alles oder nichts, ein Commit): Form-Zeile und Bestätigung sperren;
  Sitzung/Frische/Rechte/CSRF/Bindungen/Ablauf/`consumed_at` prüfen; Entwurfsrevision und neu berechneten Hash gegen
  Bestätigung prüfen; dann `form_versions` (`version_no` = Max+1), `view_versions`, `workflow_versions`,
  `resource_versions` (Semver je Ressource eindeutig), `releases` (`release_version_no` = Max+1), `release_views`,
  `audit_events`, Bestätigung `consumed_at`+`release_id`, Ledger `complete`, `forms.current_release_id`.
  Domainbindungen bleiben unberührt (ADR 0005 D1, kein `rebind` in P5-B).
- Unveränderliche Versionen: gleiche (Ressource, Semver) mit anderem Hash → 409; mit gleichem Hash wird die Zeile
  wiederverwendet. `workflow_id` = `document.flow.id`, `view_id` = `view.id`; `document.form.id` muss `formId`
  entsprechen, alle `tenantId` dem Pfadkunden (sonst 422).
- Umfang (VORGESCHLAGEN, Scope-Reduktion): `modules`, `blocks`, `scripts`, `sandboxProfiles` leer; Graph nur Knoten
  `entry` und `end`, sonst 422 (`validation_failed`); Ansichten 1..n; `storage.adapter=db` (s3/sftp → 422, keine
  Verbindungsauflösung). Abbildung auf `form_versions`: `encryption_profile=security.encryptionProfile`,
  `transport_policy=security.transport`, `validation_profile=typed-v1`, `legacy_adapter_ref=NULL`.
  Nicht ableitbar: `special_categories` (**F3**), `max_upload_bytes` vs. `storage.maxSubmissionBytes` (**F3**),
  Aktivierung `forms.active` (**F8**).
- Validierung des Dokuments gegen `form/view/graph.schema.json`: Tiefe (volles Schema vs. handgeschriebene Teilmenge,
  Swift hat keinen eingebundenen JSON-Schema-Validator) ist Implementierungsrisiko, siehe Offen-Datei R1.

## E8 Zeitkanäle (VORGESCHLAGEN)
- Dummy-Verifikation: **ja.** Unbekannte Credential-ID, UserHandle-Fehler und verbrauchte Challenge durchlaufen
  denselben Pfad inklusive einer Signaturprüfung mit festem synthetischem Dummy-Schlüssel; falsches Passwort im
  Zweitfaktor und fehlender Hash durchlaufen die Dummy-Hashprüfung (`anmeldung.md`: gleichwertiger Dummy-Hashpfad).
- Mindestlaufzeit/künstliche Verzögerung: **nein** (`anmeldung.md`: keine blockierenden Sleeps; Backoff läuft über
  `Retry-After`). Restrisiko (DB-Lesezeitunterschiede) bleibt dokumentiert; strukturelle Prüfung statt Zeitmessung:
  Test, dass jeder Fehlerpfad Dummy-Verifikation und dieselbe Zahl Zähler-/Challenge-Schreibzugriffe ausführt.

## Prüfkriterien (Auszug, ergänzen die Abnahmefälle des Paketvertrags)
`bash backend/db/check.sh` grün inkl. `form_drafts`-Abschnitt; `cmp` Schema identisch; `validate.py` Auth/Flow grün;
Fehlerhüllentest mit identischer Antwort für alle Passkeyfehler; Challenge-Verbrauch übersteht Rollback; Draft-
Race (zwei parallele `updateDraft` mit gleicher Revision: genau einer gewinnt).
