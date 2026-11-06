-- SPDX-License-Identifier: AGPL-3.0-only
-- P2-3, 2026-10-26: ENTWURF, NICHT AUSGEFUEHRT, KEINE MIGRATION.
-- OFFEN: MariaDB-/Fluent-Mindestversion, Index-/CHECK-Kompatibilitaet,
-- Kollation und Detailvertraege. Nicht als ausfuehrbar oder produktionsreif zugesagt.
-- Technische Ergänzungen 27.10.2026: VORGESCHLAGEN, siehe abbildung.md und objektinventar.md.
-- Alle Tabellen: InnoDB, explizite Besitzer in COMMENT; Zeiten UTC.
-- RESTRICT ist ein Entwurf fuer koordinierte Loeschdienste, keine Altparitaetszusage.

CREATE TABLE customers (
    id BINARY(16) NOT NULL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    state ENUM('active','disabled') NOT NULL,
    created_at DATETIME(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE accounts (
    id BINARY(16) NOT NULL PRIMARY KEY,
    username VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    template_name VARCHAR(120) NULL COMMENT 'Vorlage, kein Autorisierungsrecht',
    active BOOLEAN NOT NULL,
    mcp_allowed BOOLEAN NOT NULL,
    mfa_secret_ref VARCHAR(255) NULL,
    rights_version BIGINT UNSIGNED NOT NULL DEFAULT 0,
    created_at DATETIME(6) NULL,
    last_login_at DATETIME(6) NULL,
    UNIQUE KEY uq_account_username (username)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE customer_memberships (
    customer_id BINARY(16) NOT NULL,
    account_id BINARY(16) NOT NULL,
    template_name VARCHAR(120) NULL COMMENT 'Vorlage, kein Autorisierungsrecht',
    access_scope ENUM('assigned-forms','all-forms') NOT NULL,
    granted_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,account_id),
    KEY ix_membership_account (account_id),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE forms (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    name VARCHAR(255) NULL,
    active BOOLEAN NOT NULL DEFAULT 0,
    current_release_id BINARY(16) NULL,
    created_at DATETIME(6) NULL,
    UNIQUE KEY uq_form_tenant (customer_id,id),
    FOREIGN KEY (customer_id) REFERENCES customers(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

CREATE TABLE form_access (
    customer_id BINARY(16) NOT NULL,
    account_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    granted_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,account_id,form_id),
    KEY ix_access_form (customer_id,form_id),
    FOREIGN KEY (customer_id,account_id) REFERENCES customer_memberships(customer_id,account_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE form_versions (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    version_no BIGINT UNSIGNED NOT NULL,
    contract_version VARCHAR(32) NOT NULL,
    definition_json JSON NOT NULL,
    definition_sha256 BINARY(32) NOT NULL,
    encryption_profile ENUM('hpke-v2') NOT NULL,
    -- Vertragsrunde 3 R05 (VORGESCHLAGEN): Teil der versionierten, bestaetigten Definition.
    transport_policy ENUM('off','offered','required') NOT NULL DEFAULT 'off',
    validation_profile ENUM('typed-v1','legacy-v1') NOT NULL,
    legacy_adapter_ref VARCHAR(255) NULL,
    CHECK ((validation_profile='typed-v1' AND legacy_adapter_ref IS NULL) OR
           (validation_profile='legacy-v1' AND legacy_adapter_ref IS NOT NULL)),
    special_categories BOOLEAN NOT NULL,
    storage_backend ENUM('db','s3','sftp') NOT NULL,
    storage_connection_id BINARY(16) NULL,
    max_upload_bytes BIGINT UNSIGNED NOT NULL,
    created_by BINARY(16) NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,form_id,version_no),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (created_by) REFERENCES accounts(id),
    CHECK (version_no > 0 AND max_upload_bytes > 0),
    CHECK ((storage_backend = 'db' AND storage_connection_id IS NULL) OR
           (storage_backend IN ('s3','sftp') AND storage_connection_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

CREATE TABLE view_versions (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    view_id BINARY(16) NOT NULL,
    version_no BIGINT UNSIGNED NOT NULL,
    contract_version VARCHAR(32) NOT NULL,
    definition_json JSON NOT NULL,
    definition_sha256 BINARY(32) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,form_id,view_id,version_no),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK (version_no > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

CREATE TABLE workflow_versions (
    customer_id BINARY(16) NOT NULL,
    workflow_id BINARY(16) NOT NULL,
    version_no BIGINT UNSIGNED NOT NULL,
    contract_version VARCHAR(32) NOT NULL,
    graph_json JSON NOT NULL,
    graph_sha256 BINARY(32) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,workflow_id,version_no),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    CHECK (version_no > 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE releases (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    form_version_no BIGINT UNSIGNED NOT NULL,
    workflow_id BINARY(16) NOT NULL,
    workflow_version_no BIGINT UNSIGNED NOT NULL,
    release_version_no BIGINT UNSIGNED NOT NULL,
    dependency_manifest_json JSON NOT NULL,
    manifest_sha256 BINARY(32) NOT NULL,
    confirmed_by BINARY(16) NOT NULL,
    confirmed_at DATETIME(6) NOT NULL,
    confirmation_audit_id BINARY(16) NOT NULL,
    UNIQUE KEY uq_release_tenant (customer_id,form_id,id),
    UNIQUE KEY uq_release_version (customer_id,form_id,release_version_no),
    FOREIGN KEY (customer_id,form_id,form_version_no) REFERENCES form_versions(customer_id,form_id,version_no),
    FOREIGN KEY (customer_id,workflow_id,workflow_version_no) REFERENCES workflow_versions(customer_id,workflow_id,version_no),
    FOREIGN KEY (confirmed_by) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

CREATE TABLE release_views (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    release_id BINARY(16) NOT NULL,
    view_id BINARY(16) NOT NULL,
    view_version_no BIGINT UNSIGNED NOT NULL,
    PRIMARY KEY (customer_id,form_id,release_id,view_id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,view_id,view_version_no) REFERENCES view_versions(customer_id,form_id,view_id,version_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

ALTER TABLE forms ADD CONSTRAINT fk_form_current_release
    FOREIGN KEY (customer_id,id,current_release_id) REFERENCES releases(customer_id,form_id,id);

-- P5-B E1 (ADR 0007 Nr. 3, VORGESCHLAGEN): veraenderlicher Entwurf (Draft{id,revision,hash,document}).
-- Genau ein aktueller Stand je Entwurf; revision zaehlt je erfolgreichem Schreiben um 1 (Dienst: bedingtes
-- UPDATE ... WHERE revision=? unter Zeilensperre; If-Match/ETag = revision). document_sha256 = SHA-256 der
-- kanonischen Serialisierung von document_json (Verfahren: ../auth/p5b-ergaenzung.md E5, vom Dienst
-- berechnet, nie vom Client uebernommen). Keine Historie alter Revisionen; unveraenderlich ist erst die Version.
CREATE TABLE form_drafts (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
    base_release_id BINARY(16) NULL COMMENT 'Release, aus dem der Entwurf angelegt wurde; NULL = ohne Basis',
    document_json JSON NOT NULL,
    document_sha256 BINARY(32) NOT NULL,
    created_by BINARY(16) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    updated_by BINARY(16) NOT NULL,
    updated_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_draft_tenant (customer_id,form_id,id),
    KEY ix_draft_form (customer_id,form_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,base_release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (created_by) REFERENCES accounts(id),
    FOREIGN KEY (updated_by) REFERENCES accounts(id),
    CHECK (revision > 0),
    CHECK (updated_at >= created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

-- Vertragsrunde 3 R01 (VORGESCHLAGEN): Auslieferungsstand der Domain ist persistiert.
-- Auslieferung eines Ansichtshosts nutzt AUSSCHLIESSLICH (release_id, view_id) dieser Zeile,
-- niemals forms.current_release_id. Release-Wechsel einer produktiven Bindung ist eine
-- bestaetigte Domainaenderung (revision+1), siehe ../auth/domains-proxy.md.
CREATE TABLE domain_bindings (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    host_ascii VARCHAR(253) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    environment ENUM('production','test') NOT NULL,
    release_id BINARY(16) NULL,
    view_id BINARY(16) NULL,
    enabled BOOLEAN NOT NULL,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
    changed_by BINARY(16) NOT NULL,
    changed_at DATETIME(6) NOT NULL,
    confirmation_audit_id BINARY(16) NULL COMMENT 'Audit-Beleg der menschlichen Bestaetigung dieser revision',
    UNIQUE KEY uq_view_host (host_ascii),
    KEY ix_domain_tenant (customer_id,form_id),
    KEY ix_domain_release (customer_id,form_id,release_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,release_id,view_id) REFERENCES release_views(customer_id,form_id,release_id,view_id),
    FOREIGN KEY (changed_by) REFERENCES accounts(id),
    CHECK (enabled=0 OR (release_id IS NOT NULL AND view_id IS NOT NULL)),
    CHECK (environment<>'production' OR enabled=0 OR confirmation_audit_id IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Domainzuordnung';

CREATE TABLE connections (
    id BINARY(16) NOT NULL PRIMARY KEY,
    kind ENUM('smtp','mail-proxy','s3','sftp','test-target','ftp') NOT NULL,
    name VARCHAR(255) NOT NULL,
    safe_config_json JSON NOT NULL,
    credential_ref VARCHAR(255) NULL,
    enabled BOOLEAN NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

CREATE TABLE customer_connections (
    customer_id BINARY(16) NOT NULL,
    connection_id BINARY(16) NOT NULL,
    PRIMARY KEY (customer_id,connection_id),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (connection_id) REFERENCES connections(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

ALTER TABLE form_versions ADD CONSTRAINT fk_form_storage_connection
    FOREIGN KEY (customer_id,storage_connection_id) REFERENCES customer_connections(customer_id,connection_id);

CREATE TABLE form_connections (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    environment ENUM('production','test') NOT NULL,
    purpose VARCHAR(64) NOT NULL,
    connection_id BINARY(16) NOT NULL,
    PRIMARY KEY (customer_id,form_id,environment,purpose),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,connection_id) REFERENCES customer_connections(customer_id,connection_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

-- ADR 0011: SDK self-update. One target per form (production), history of every run.
CREATE TABLE sdk_targets (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    connection_id BINARY(16) NOT NULL,
    remote_dir VARCHAR(240) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
    auto_update BOOLEAN NOT NULL DEFAULT 0,
    installed_version VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    previous_version VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    last_attempt_version VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    last_result VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL,
    updated_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,form_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,connection_id) REFERENCES customer_connections(customer_id,connection_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen; ADR 0011';

CREATE TABLE sdk_deployments (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    action ENUM('install','rollback') NOT NULL,
    trigger_kind ENUM('manual','auto') NOT NULL,
    from_version VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    to_version VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL,
    result ENUM('ok','failed') NOT NULL,
    error_code VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL,
    actor_id BINARY(16) NULL,
    started_at DATETIME(6) NOT NULL,
    finished_at DATETIME(6) NOT NULL,
    KEY ix_sdk_deployments (customer_id,form_id,started_at),
    FOREIGN KEY (customer_id,form_id) REFERENCES sdk_targets(customer_id,form_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen; ADR 0011';

CREATE TABLE settings (
    scope_key VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    setting_key VARCHAR(190) NOT NULL,
    safe_value_json JSON NULL,
    secret_ref VARCHAR(255) NULL,
    manageable BOOLEAN NOT NULL,
    modified_at DATETIME(6) NOT NULL,
    PRIMARY KEY (scope_key,setting_key),
    CHECK ((safe_value_json IS NULL) <> (secret_ref IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

CREATE TABLE account_preferences (
    account_id BINARY(16) NOT NULL,
    preference_key VARCHAR(64) NOT NULL,
    safe_value_json JSON NOT NULL,
    modified_at DATETIME(6) NOT NULL,
    PRIMARY KEY (account_id,preference_key),
    FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE passkeys (
    credential_id VARBINARY(255) NOT NULL PRIMARY KEY,
    account_id BINARY(16) NOT NULL,
    user_handle VARBINARY(36) NOT NULL COMMENT 'VORGESCHLAGEN: UTF-8-Bytes des UUID-Textes des Kontos (36 ASCII-Bytes), wie Altbestand',
    public_key_bytes BLOB NOT NULL,
    public_key_encoding VARCHAR(32) NOT NULL COMMENT 'VORGESCHLAGEN: fester Wert pem-spki (PEM/SubjectPublicKeyInfo unveraendert)',
    cose_algorithm SMALLINT NOT NULL COMMENT 'VORGESCHLAGEN: COSE-Algorithmus -7 ES256, -257 RS256, -8 EdDSA',
    sign_count BIGINT UNSIGNED NOT NULL,
    label VARCHAR(120) NOT NULL,
    rp_id VARCHAR(253) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    created_at DATETIME(6) NOT NULL,
    last_used_at DATETIME(6) NULL,
    UNIQUE KEY uq_passkey_account (account_id,credential_id),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    CHECK (OCTET_LENGTH(credential_id) BETWEEN 1 AND 255),
    CHECK (sign_count <= 4294967295),
    CHECK (public_key_encoding = 'pem-spki'),
    CHECK (cose_algorithm IN (-7,-257,-8)),
    CHECK (OCTET_LENGTH(user_handle) = 36
        AND SUBSTRING(user_handle,9,1) = x'2D' AND SUBSTRING(user_handle,14,1) = x'2D'
        AND SUBSTRING(user_handle,19,1) = x'2D' AND SUBSTRING(user_handle,24,1) = x'2D'
        AND LOWER(REPLACE(CONVERT(user_handle USING ascii),'-','')) = LOWER(HEX(account_id)))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE account_keys (
    account_id BINARY(16) NOT NULL PRIMARY KEY,
    public_key VARBINARY(32) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    CHECK (OCTET_LENGTH(public_key) = 32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE account_key_wraps (
    credential_id VARBINARY(255) NOT NULL PRIMARY KEY,
    account_id BINARY(16) NOT NULL,
    prf_salt VARBINARY(32) NOT NULL,
    iv VARBINARY(12) NOT NULL,
    wrapped_key VARBINARY(48) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (account_id) REFERENCES account_keys(account_id),
    FOREIGN KEY (account_id,credential_id) REFERENCES passkeys(account_id,credential_id),
    CHECK (OCTET_LENGTH(prf_salt)=32 AND OCTET_LENGTH(iv)=12 AND OCTET_LENGTH(wrapped_key)=48)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE customer_key_generations (
    generation_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    kid CHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    generation_no BIGINT UNSIGNED NOT NULL,
    public_key VARBINARY(32) NOT NULL,
    state ENUM('active','retiring') NOT NULL,
    active_slot TINYINT GENERATED ALWAYS AS (CASE WHEN state='active' THEN 1 ELSE NULL END) PERSISTENT,
    created_by BINARY(16) NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,kid),
    UNIQUE KEY uq_generation_id (generation_id),
    UNIQUE KEY uq_generation_customer_id (customer_id,generation_id),
    UNIQUE KEY uq_customer_generation (customer_id,generation_no),
    UNIQUE KEY uq_customer_active_key (customer_id,active_slot),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    CHECK (generation_no > 0 AND OCTET_LENGTH(public_key)=32),
    CHECK (kid REGEXP '^[0-9a-f]{16}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE data_key_access (
    customer_id BINARY(16) NOT NULL,
    kid CHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    account_id BINARY(16) NOT NULL,
    enc VARBINARY(32) NOT NULL,
    sealed_key VARBINARY(48) NOT NULL,
    granted_by BINARY(16) NULL,
    granted_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,kid,account_id),
    KEY ix_key_access_account (account_id),
    FOREIGN KEY (customer_id,kid) REFERENCES customer_key_generations(customer_id,kid),
    FOREIGN KEY (account_id) REFERENCES account_keys(account_id),
    CHECK (OCTET_LENGTH(enc)=32 AND OCTET_LENGTH(sealed_key)=48)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE data_key_recovery (
    customer_id BINARY(16) NOT NULL,
    kid CHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    kdf_name VARCHAR(40) NOT NULL,
    salt VARBINARY(32) NOT NULL,
    iterations INT UNSIGNED NOT NULL,
    iv VARBINARY(12) NOT NULL,
    wrapped_key VARBINARY(48) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,kid),
    FOREIGN KEY (customer_id,kid) REFERENCES customer_key_generations(customer_id,kid),
    CHECK (iterations > 0 AND OCTET_LENGTH(salt)=32 AND OCTET_LENGTH(iv)=12 AND OCTET_LENGTH(wrapped_key)=48)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE form_protocol_keys (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    purpose ENUM('client-ua','client-ip','ed25519','transport','digest-hmac') NOT NULL, -- Runde 4 D1: digest-hmac = HMAC-Schluessel fuer persistierte request_digest (nur secret_ref)
    generation_no BIGINT UNSIGNED NOT NULL,
    public_key VARBINARY(32) NULL,
    secret_ref VARCHAR(255) NULL,
    state ENUM('current','previous','revoked') NOT NULL,
    current_slot TINYINT GENERATED ALWAYS AS (CASE WHEN state='current' THEN 1 ELSE NULL END) PERSISTENT,
    valid_until DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,form_id,purpose,generation_no),
    UNIQUE KEY uq_protocol_current (customer_id,form_id,purpose,current_slot),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK ((purpose='ed25519' AND public_key IS NOT NULL AND OCTET_LENGTH(public_key)=32 AND secret_ref IS NULL)
        OR (purpose<>'ed25519' AND public_key IS NULL AND secret_ref IS NOT NULL)),
    CHECK (state<>'previous' OR valid_until IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie';

CREATE TABLE signature_exceptions (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    valid_from DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    granted_by BINARY(16) NOT NULL,
    reason_code VARCHAR(64) NOT NULL,
    audit_id BINARY(16) NOT NULL,
    KEY ix_signature_exception (customer_id,form_id,expires_at),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (granted_by) REFERENCES accounts(id),
    CHECK (expires_at > valid_from)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';

CREATE TABLE submissions (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    release_id BINARY(16) NULL,
    release_evidence ENUM('recorded','legacy-unknown') NOT NULL,
    received_at DATETIME(6) NULL,
    environment ENUM('production','test','legacy-unknown') NOT NULL,
    state ENUM('accepted','rejected','migration-review') NOT NULL,
    removable BOOLEAN NOT NULL,
    retention_due_at DATETIME(6) NULL,
    malware_scan_status VARCHAR(32) NOT NULL,
    captcha_status VARCHAR(32) NOT NULL DEFAULT 'disabled',
    legacy_sent_server VARCHAR(255) NULL,
    UNIQUE KEY uq_submission_tenant (customer_id,form_id,id),
    KEY ix_submission_history (customer_id,form_id,received_at,id),
    KEY ix_submission_retention (removable,retention_due_at),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    CHECK ((release_evidence='recorded' AND release_id IS NOT NULL) OR
           (release_evidence='legacy-unknown' AND release_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';

CREATE TABLE stored_objects (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    submission_id BINARY(16) NULL,
    object_role ENUM('data','attachment','mail-organisation','mail-filler','mail-manifest','legacy-errors','checkpoint','debug','object-metadata','statistics-metadata') NOT NULL,
    ordinal_no INT UNSIGNED NOT NULL DEFAULT 0,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    expires_at DATETIME(6) NULL,
    backend ENUM('db','s3','sftp') NOT NULL,
    connection_id BINARY(16) NULL,
    object_key VARBINARY(1024) NULL,
    ciphertext LONGBLOB NULL,
    packet_format ENUM('KUBUS-AEAD:2') NOT NULL,
    wrap_kind ENUM('hpke','sym') NOT NULL,
    kid CHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    metadata_object_id BINARY(16) NULL,
    content_encoding ENUM('raw','legacy-json-force-object','legacy-base64-trimmed-mail') NOT NULL,
    ciphertext_sha256 BINARY(32) NOT NULL,
    byte_count BIGINT UNSIGNED NOT NULL,
    state ENUM('prepared','ready','deleting','failed') NOT NULL,
    UNIQUE KEY uq_submission_object (customer_id,form_id,submission_id,object_role,ordinal_no),
    UNIQUE KEY uq_object_tenant (customer_id,form_id,id),
    KEY ix_object_expiry (expires_at),
    KEY ix_object_key_generation (customer_id,kid),
    KEY ix_object_cleanup (state),
    FOREIGN KEY (customer_id,form_id,submission_id) REFERENCES submissions(customer_id,form_id,id),
    FOREIGN KEY (customer_id,kid) REFERENCES customer_key_generations(customer_id,kid),
    FOREIGN KEY (customer_id,connection_id) REFERENCES customer_connections(customer_id,connection_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,metadata_object_id) REFERENCES stored_objects(customer_id,form_id,id),
    CHECK (object_role NOT IN ('data','attachment','mail-organisation','mail-filler','mail-manifest','legacy-errors','checkpoint') OR submission_id IS NOT NULL),
    CHECK (object_role<>'debug' OR expires_at IS NOT NULL),
    CHECK ((backend='db' AND ciphertext IS NOT NULL AND object_key IS NULL AND connection_id IS NULL) OR
           (backend IN ('s3','sftp') AND ciphertext IS NULL AND object_key IS NOT NULL AND connection_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Speicher';

-- ADR 0019: durable, ciphertext-only spool; removed after confirmed upload/deletion.
CREATE TABLE storage_uploads (
    object_id BINARY(16) NOT NULL PRIMARY KEY,
    ciphertext LONGBLOB NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (object_id) REFERENCES stored_objects(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Speicher; ADR 0019';

CREATE TABLE ingest_idempotency (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    key_digest BINARY(32) NOT NULL,
    legacy_raw_key VARBINARY(190) NULL,
    submission_id BINARY(16) NOT NULL,
    request_digest BINARY(32) NULL COMMENT 'Runde 4 D1: HMAC-SHA256 (K_digest je Formular/Generation) ueber den Fachdigest, nicht der rohe Digest',
    digest_key_generation BIGINT UNSIGNED NULL COMMENT 'Runde 4 D1: Generation von form_protocol_keys purpose=digest-hmac',
    environment ENUM('production','test','legacy-unknown') NOT NULL,
    release_id BINARY(16) NULL,
    release_evidence ENUM('recorded','legacy-unknown') NOT NULL,
    result_state ENUM('pending','available','deleted') NOT NULL,
    digest_evidence ENUM('verified','legacy-missing') NOT NULL,
    state ENUM('reserved','complete','review') NOT NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NULL,
    PRIMARY KEY (customer_id,form_id,key_digest),
    KEY ix_idempotency_expiry (expires_at),
    KEY ix_idempotency_submission (submission_id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    CHECK ((release_evidence='recorded' AND release_id IS NOT NULL) OR (release_evidence='legacy-unknown' AND release_id IS NULL)),
    CHECK (legacy_raw_key IS NULL OR OCTET_LENGTH(legacy_raw_key) BETWEEN 1 AND 190),
    CHECK ((digest_evidence='verified' AND request_digest IS NOT NULL AND digest_key_generation IS NOT NULL) OR
           (digest_evidence='legacy-missing' AND request_digest IS NULL AND digest_key_generation IS NULL)),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';

CREATE TABLE workflow_runs (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    submission_id BINARY(16) NOT NULL,
    release_id BINARY(16) NOT NULL,
    run_slot VARCHAR(64) NOT NULL,
    idempotency_key VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    request_digest BINARY(32) NOT NULL COMMENT 'Runde 4 D1: HMAC-Form wie ingest_idempotency.request_digest',
    digest_key_generation BIGINT UNSIGNED NOT NULL COMMENT 'Runde 4 D1',
    retain_until DATETIME(6) NOT NULL,
    state ENUM('ready','running','waiting','waiting-manual','paused','complete','failed','uncertain','cancelled') NOT NULL,
    continuation_policy ENUM('human-after-wait-or-crash') NOT NULL,
    environment ENUM('production','test') NOT NULL,
    suspension_json JSON NULL,
    checkpoint_object_id BINARY(16) NOT NULL,
    checkpoint_json JSON NOT NULL,
    budget_json JSON NOT NULL,
    steps_used BIGINT UNSIGNED NOT NULL DEFAULT 0,
    active_time_ms BIGINT UNSIGNED NOT NULL DEFAULT 0,
    wake_at DATETIME(6) NULL,
    deadline_at DATETIME(6) NOT NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    UNIQUE KEY uq_run_slot (customer_id,submission_id,release_id,run_slot),
    UNIQUE KEY uq_run_tenant (customer_id,form_id,id),
    KEY ix_run_claim (state,wake_at,lease_until),
    FOREIGN KEY (customer_id,form_id,submission_id) REFERENCES submissions(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,checkpoint_object_id) REFERENCES stored_objects(customer_id,form_id,id),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE workflow_approvals (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    run_id BINARY(16) NOT NULL,
    node_id VARCHAR(190) NOT NULL,
    visit_no BIGINT UNSIGNED NOT NULL,
    state ENUM('pending','approved','rejected','expired') NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    answered_by BINARY(16) NULL,
    answered_at DATETIME(6) NULL,
    UNIQUE KEY uq_approval_visit (run_id,node_id,visit_no),
    KEY ix_approval_due (state,expires_at),
    FOREIGN KEY (customer_id,form_id,run_id) REFERENCES workflow_runs(customer_id,form_id,id),
    FOREIGN KEY (answered_by) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE workflow_effects (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    run_id BINARY(16) NOT NULL,
    node_id VARCHAR(190) NOT NULL,
    visit_no BIGINT UNSIGNED NOT NULL,
    effect_slot VARCHAR(64) NOT NULL,
    state ENUM('prepared','in-flight','confirmed','uncertain','failed') NOT NULL,
    attempts INT UNSIGNED NOT NULL DEFAULT 0,
    last_fence BIGINT UNSIGNED NOT NULL,
    result_ref VARCHAR(255) NULL,
    UNIQUE KEY uq_effect_visit (run_id,node_id,visit_no,effect_slot),
    UNIQUE KEY uq_effect_tenant (customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,run_id) REFERENCES workflow_runs(customer_id,form_id,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE mail_deliveries (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    submission_id BINARY(16) NOT NULL,
    environment VARBINARY(16) NOT NULL,
    mail_kind VARBINARY(32) NOT NULL,
    identity_scope VARBINARY(80) NOT NULL,
    effect_id BINARY(16) NULL,
    transport_kind VARCHAR(16) NOT NULL,
    state ENUM('pending','leased','waiting-manual','smtp-accepted','abandoned','uncertain') NOT NULL,
    legacy_status VARCHAR(32) NULL,
    attempts INT UNSIGNED NOT NULL,
    next_attempt_at DATETIME(6) NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    last_error_code VARCHAR(64) NULL,
    created_at DATETIME(6) NOT NULL,
    updated_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_mail_identity (submission_id,environment,mail_kind,identity_scope),
    UNIQUE KEY uq_mail_effect (effect_id),
    KEY ix_mail_due (state,next_attempt_at,lease_until),
    FOREIGN KEY (customer_id,form_id,submission_id) REFERENCES submissions(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,effect_id) REFERENCES workflow_effects(customer_id,form_id,id),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Zustellung';

CREATE TABLE webhook_endpoints (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    target_url VARCHAR(2048) NOT NULL,
    signing_secret_ref VARCHAR(255) NOT NULL,
    public_key VARBINARY(32) NOT NULL,
    active BOOLEAN NOT NULL,
    created_by BINARY(16) NULL,
    created_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_webhook_tenant (customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK (OCTET_LENGTH(public_key)=32)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Zustellung';

CREATE TABLE webhook_outbox (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    webhook_id BINARY(16) NOT NULL,
    submission_id BINARY(16) NOT NULL,
    received_at DATETIME(6) NOT NULL,
    effect_id BINARY(16) NULL,
    state ENUM('prepared','ready','leased','succeeded','failed-terminal','uncertain') NOT NULL,
    legacy_status VARCHAR(32) NULL,
    attempts INT UNSIGNED NOT NULL,
    next_attempt_at DATETIME(6) NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    last_error_code VARCHAR(64) NULL,
    created_at DATETIME(6) NOT NULL,
    completed_at DATETIME(6) NULL,
    UNIQUE KEY uq_webhook_effect (effect_id),
    KEY ix_outbox_claim (state,next_attempt_at,lease_until),
    KEY ix_outbox_submission (submission_id),
    FOREIGN KEY (customer_id,form_id,webhook_id) REFERENCES webhook_endpoints(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,effect_id) REFERENCES workflow_effects(customer_id,form_id,id),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Zustellung';

CREATE TABLE managed_secrets (
    ref VARCHAR(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY COMMENT 'Referenz s1:<uuid>; steht in secret_ref-Spalten',
    ciphertext VARBINARY(256) NOT NULL COMMENT 'AES-256-GCM nonce||ct||tag unter einem aus dem Serverschluessel abgeleiteten Schluessel, AAD = ref',
    key_version SMALLINT UNSIGNED NOT NULL DEFAULT 1,
    created_at DATETIME(6) NOT NULL,
    CHECK (OCTET_LENGTH(ciphertext) BETWEEN 29 AND 256)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kryptografie; ADR 0006 Nr. 6 (D9): Secrets verschluesselt in der DB, Hauptschluessel aus der Betriebsumgebung';

CREATE TABLE account_enrollments (
    id BINARY(16) NOT NULL PRIMARY KEY,
    account_id BINARY(16) NOT NULL,
    token_hash BINARY(32) NOT NULL COMMENT 'SHA-256 des 256-Bit-Einrichtungs-Tokens; das Token selbst wird nie gespeichert',
    purpose ENUM('first-passkey','recovery-passkey') NOT NULL,
    created_by BINARY(16) NULL COMMENT 'NULL = Betreiber-Kommando (bootstrap-admin/enroll-passkey)',
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    consumed_at DATETIME(6) NULL,
    UNIQUE KEY uq_enrollment_token (token_hash),
    KEY ix_enrollment_account (account_id),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    FOREIGN KEY (created_by) REFERENCES accounts(id),
    CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL 7 DAY)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte; P5-B Einrichtung des ersten/ersetzten Passkeys, einmalig, hoechstens 7 Tage';

CREATE TABLE sessions (
    id BINARY(16) NOT NULL PRIMARY KEY,
    token_hash BINARY(32) NOT NULL,
    account_id BINARY(16) NULL,
    state ENUM('anonymous','factor_pending','authenticated','revoked','expired') NOT NULL,
    auth_level VARCHAR(32) NOT NULL,
    auth_method VARCHAR(32) NULL,
    authenticated_at DATETIME(6) NULL,
    rights_version BIGINT UNSIGNED NULL,
    primary_factor_at DATETIME(6) NULL,
    second_factor_at DATETIME(6) NULL,
    csrf_secret_ciphertext VARBINARY(256) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    last_seen_at DATETIME(6) NOT NULL,
    idle_expires_at DATETIME(6) NOT NULL,
    absolute_expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    replaced_by BINARY(16) NULL,
    UNIQUE KEY uq_session_token (token_hash),
    KEY ix_session_account (account_id),
    KEY ix_session_expiry (absolute_expires_at,idle_expires_at),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    FOREIGN KEY (replaced_by) REFERENCES sessions(id),
    CHECK (state NOT IN ('factor_pending','authenticated') OR account_id IS NOT NULL),
    CHECK (state<>'authenticated' OR (authenticated_at IS NOT NULL AND auth_method IS NOT NULL AND rights_version IS NOT NULL)),
    CHECK (state<>'anonymous' OR account_id IS NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE auth_challenges (
    id BINARY(16) NOT NULL PRIMARY KEY,
    session_id BINARY(16) NOT NULL,
    account_id BINARY(16) NULL,
    purpose ENUM('passkey-login','passkey-register','totp-enroll','second-factor','fresh-auth') NOT NULL,
    challenge_hash BINARY(32) NULL,
    enrollment_secret_ref VARCHAR(255) NULL,
    factor_revision BIGINT UNSIGNED NULL,
    factor_method VARCHAR(32) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    consumed_at DATETIME(6) NULL,
    revoked_at DATETIME(6) NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    CHECK (expires_at>created_at),
    CHECK (purpose NOT IN ('passkey-login','passkey-register') OR challenge_hash IS NOT NULL),
    CHECK (purpose NOT IN ('passkey-login','passkey-register') OR expires_at <= created_at + INTERVAL 120 SECOND)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE totp_replay_state (
    account_id BINARY(16) NOT NULL PRIMARY KEY,
    factor_revision BIGINT UNSIGNED NOT NULL,
    last_accepted_step BIGINT NOT NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE publication_confirmations (
    id BINARY(16) NOT NULL PRIMARY KEY,
    session_id BINARY(16) NOT NULL,
    account_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    draft_id BINARY(16) NOT NULL,
    draft_revision BIGINT UNSIGNED NOT NULL,
    candidate_sha256 BINARY(32) NOT NULL,
    authenticated_at DATETIME(6) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    consumed_at DATETIME(6) NULL,
    release_id BINARY(16) NULL,
    revoked_at DATETIME(6) NULL,
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,draft_id) REFERENCES form_drafts(customer_id,form_id,id),
    CHECK (expires_at>created_at),
    CHECK ((consumed_at IS NULL) = (release_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE auth_throttles (
    scope ENUM('account','ip','totp','admin-route') NOT NULL,
    subject_hmac BINARY(32) NOT NULL,
    window_start DATETIME(6) NOT NULL,
    failures INT UNSIGNED NOT NULL,
    locked_until DATETIME(6) NULL,
    expires_at DATETIME(6) NOT NULL,
    PRIMARY KEY (scope,subject_hmac,window_start),
    KEY ix_throttle_expiry (expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE trusted_networks (
    id BINARY(16) NOT NULL PRIMARY KEY,
    cidr VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    label VARCHAR(120) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    created_by BINARY(16) NULL,
    UNIQUE KEY uq_trusted_cidr (cidr)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';

CREATE TABLE job_leases (
    scope_key VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    job_key VARCHAR(190) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    state ENUM('ready','running','failed','complete') NOT NULL,
    next_run_at DATETIME(6) NOT NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    attempts INT UNSIGNED NOT NULL DEFAULT 0,
    last_error_code VARCHAR(64) NULL,
    PRIMARY KEY (scope_key,job_key),
    KEY ix_job_claim (state,next_run_at,lease_until),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE debug_requests (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    release_id BINARY(16) NOT NULL,
    requested_by BINARY(16) NOT NULL,
    mode ENUM('test','observe') NOT NULL,
    environment ENUM('production','test') NOT NULL,
    test_connection_id BINARY(16) NULL,
    correlation_hmac BINARY(32) NULL,
    state ENUM('waiting','recording','complete','expired','cancelled') NOT NULL,
    submission_id BINARY(16) NULL,
    recording_started_at DATETIME(6) NULL,
    expires_at DATETIME(6) NOT NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    UNIQUE KEY uq_debug_tenant (customer_id,form_id,id),
    KEY ix_debug_match (customer_id,form_id,state,expires_at),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (customer_id,form_id,submission_id) REFERENCES submissions(customer_id,form_id,id),
    FOREIGN KEY (customer_id,test_connection_id) REFERENCES customer_connections(customer_id,connection_id),
    FOREIGN KEY (requested_by) REFERENCES accounts(id),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL)),
    CHECK (recording_started_at IS NULL OR expires_at=DATE_ADD(recording_started_at,INTERVAL 15 MINUTE))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE debug_events (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    debug_request_id BINARY(16) NOT NULL,
    sequence_no BIGINT UNSIGNED NOT NULL,
    occurred_at DATETIME(6) NOT NULL,
    masked_event_json JSON NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    PRIMARY KEY (customer_id,form_id,debug_request_id,sequence_no),
    KEY ix_debug_expiry (expires_at),
    FOREIGN KEY (customer_id,form_id,debug_request_id) REFERENCES debug_requests(customer_id,form_id,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

CREATE TABLE statistics_events (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    release_id BINARY(16) NOT NULL,
    view_id BINARY(16) NOT NULL,
    domain_alias BINARY(16) NOT NULL,
    visit_pseudonym VARBINARY(32) NOT NULL,
    event_kind ENUM('visit','begin','submit','abandon') NOT NULL,
    source ENUM('client','ingest','collector') NOT NULL,
    environment ENUM('production','test') NOT NULL,
    submission_id BINARY(16) NULL,
    abandonment_evidence ENUM('client-signal','inactivity-inferred') NULL,
    step_id VARCHAR(190) NULL,
    occurred_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_statistics_visit_event (customer_id,form_id,release_id,view_id,domain_alias,environment,visit_pseudonym,event_kind),
    UNIQUE KEY uq_statistics_submit (customer_id,submission_id,event_kind),
    KEY ix_statistics_query (customer_id,form_id,environment,occurred_at),
    KEY ix_statistics_expiry (expires_at),
    FOREIGN KEY (customer_id,form_id,release_id,view_id) REFERENCES release_views(customer_id,form_id,release_id,view_id),
    CHECK ((event_kind='submit' AND submission_id IS NOT NULL AND source='ingest') OR
           (event_kind<>'submit' AND submission_id IS NULL)),
    CHECK ((event_kind='abandon') = (abandonment_evidence IS NOT NULL)),
    CHECK (OCTET_LENGTH(visit_pseudonym) BETWEEN 16 AND 32),
    CHECK (expires_at=DATE_ADD(occurred_at,INTERVAL 13 MONTH))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Statistik und Audit';

CREATE TABLE legacy_statistics (
    source_id BIGINT UNSIGNED NOT NULL,
    source_namespace VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    legacy_uuid BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    occurred_at DATETIME(6) NOT NULL,
    legacy_status VARCHAR(40) NOT NULL,
    legacy_type VARCHAR(16) NULL,
    domain VARCHAR(255) NULL,
    metadata_object_id BINARY(16) NULL,
    origin ENUM('legacy') NOT NULL DEFAULT 'legacy',
    PRIMARY KEY (source_namespace,source_id),
    KEY ix_legacy_statistics_query (customer_id,form_id,occurred_at,legacy_type,legacy_status),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,metadata_object_id) REFERENCES stored_objects(customer_id,form_id,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Statistik und Audit';

CREATE TABLE audit_events (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NULL,
    form_id BINARY(16) NULL,
    actor_id BINARY(16) NULL,
    actor_kind ENUM('human','service','migration','legacy') NOT NULL,
    category VARCHAR(64) NOT NULL,
    action_code VARCHAR(100) NOT NULL,
    subject_id BINARY(16) NULL,
    occurred_at DATETIME(6) NOT NULL,
    safe_details_json JSON NOT NULL,
    source_namespace VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    source_table VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    source_key VARBINARY(190) NULL,
    UNIQUE KEY uq_audit_source (source_namespace,source_table,source_key),
    KEY ix_audit_tenant (customer_id,form_id,occurred_at),
    KEY ix_audit_category (category,occurred_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Statistik und Audit';

CREATE TABLE deletion_records (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NULL,
    form_id BINARY(16) NULL,
    subject_id BINARY(16) NULL,
    actor_id BINARY(16) NULL,
    category ENUM('submission','statistics') NOT NULL,
    reason_code VARCHAR(64) NOT NULL,
    range_from DATETIME(6) NULL,
    range_until DATETIME(6) NULL,
    deleted_count BIGINT UNSIGNED NOT NULL,
    deleted_at DATETIME(6) NOT NULL,
    safe_snapshot_json JSON NOT NULL,
    source_namespace VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    source_table VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    source_key VARBINARY(190) NULL,
    UNIQUE KEY uq_deletion_source (source_namespace,source_table,source_key),
    KEY ix_deletion_query (customer_id,form_id,deleted_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Statistik und Audit';

CREATE TABLE migration_runs (
    id BINARY(16) NOT NULL PRIMARY KEY,
    source_namespace VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    dump_sha256 BINARY(32) NOT NULL,
    mapping_sha256 BINARY(32) NOT NULL,
    importer_version VARCHAR(64) NOT NULL,
    state ENUM('planned','running','failed','verified','activated') NOT NULL,
    started_at DATETIME(6) NULL,
    completed_at DATETIME(6) NULL,
    report_json JSON NOT NULL,
    UNIQUE KEY uq_import_plan (source_namespace,dump_sha256,mapping_sha256,importer_version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

CREATE TABLE migration_objects (
    source_namespace VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    source_table VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    source_key VARBINARY(190) NOT NULL,
    target_table VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    target_slot VARBINARY(64) NOT NULL,
    target_key VARBINARY(512) NOT NULL,
    source_hmac BINARY(32) NOT NULL,
    target_hmac BINARY(32) NOT NULL,
    run_id BINARY(16) NOT NULL,
    PRIMARY KEY (source_namespace,source_table,source_key,target_table,target_slot),
    KEY ix_migration_run (run_id),
    FOREIGN KEY (run_id) REFERENCES migration_runs(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

CREATE TABLE migration_issues (
    id BINARY(16) NOT NULL PRIMARY KEY,
    run_id BINARY(16) NOT NULL,
    source_table VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    source_key VARBINARY(190) NOT NULL,
    issue_code VARCHAR(64) NOT NULL,
    state ENUM('open','resolved','accepted-with-decision') NOT NULL,
    decision_ref VARCHAR(255) NULL,
    reported_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_migration_issue (run_id,source_table,source_key,issue_code),
    FOREIGN KEY (run_id) REFERENCES migration_runs(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Integrationen';

-- VORGESCHLAGEN: Semver ist Inhalt; version_no nur lokale relationale Sequenz.
CREATE TABLE resource_versions (
    customer_id BINARY(16) NOT NULL,
    resource_kind ENUM('form','view','workflow','release') NOT NULL,
    resource_id BINARY(16) NOT NULL,
    semantic_version VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    version_no BIGINT UNSIGNED NOT NULL,
    content_sha256 BINARY(32) NOT NULL,
    PRIMARY KEY (customer_id,resource_kind,resource_id,semantic_version),
    UNIQUE KEY uq_resource_local_version (customer_id,resource_kind,resource_id,version_no),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    CHECK (version_no>0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Formulardefinitionen';

CREATE TABLE admin_action_idempotency (
    actor_kind ENUM('account','token','oauth') NOT NULL,
    actor_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    action_name VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    target_id BINARY(16) NOT NULL,
    key_digest BINARY(32) NOT NULL,
    request_digest BINARY(32) NOT NULL,
    result_id BINARY(16) NOT NULL,
    state ENUM('reserved','complete','uncertain','deleted') NOT NULL,
    lease_token BINARY(16) NULL,
    lease_until DATETIME(6) NULL,
    fence BIGINT UNSIGNED NOT NULL DEFAULT 0,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NULL,
    PRIMARY KEY (actor_kind,actor_id,customer_id,action_name,target_id,key_digest),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    CHECK ((lease_token IS NULL) = (lease_until IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

CREATE TABLE debug_objects (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    debug_request_id BINARY(16) NOT NULL,
    sequence_no BIGINT UNSIGNED NOT NULL,
    object_id BINARY(16) NOT NULL,
    PRIMARY KEY (customer_id,form_id,debug_request_id,sequence_no,object_id),
    FOREIGN KEY (customer_id,form_id,debug_request_id,sequence_no) REFERENCES debug_events(customer_id,form_id,debug_request_id,sequence_no),
    FOREIGN KEY (customer_id,form_id,object_id) REFERENCES stored_objects(customer_id,form_id,id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';

-- ADR 0004 Runde 2: neue technische Strukturen VORGESCHLAGEN, nicht ausgefuehrt.
-- Katalog ist geschlossen; seed identisch zu OpenAPI Permission. Kein Wildcardgrant.
CREATE TABLE permission_catalog (
    permission VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
INSERT INTO permission_catalog (permission) VALUES
    ('account.manage'),
    ('audit.read'),
    ('content.decrypt'),
    ('content.delete'),
    ('content.export'),
    ('content.hold'),
    ('content.read'),
    ('content.resend'),
    ('debug.export'),
    ('debug.plaintext'),
    ('debug.read'),
    ('domain.manage'),
    ('draft.export'),
    ('draft.write'),
    ('flow.approve'),
    ('flow.execute'),
    ('flow.resume'),
    ('form.create'),
    ('form.read'),
    ('identity.manage'),
    ('key.manage'),
    ('privacy.manage'),
    ('release.publish'),
    ('statistics.delete'),
    ('statistics.read'),
    ('system.manage'),
    ('system.settings'),
    ('migration.run'),
    ('test-target.manage'),
    ('test.run'),
    ('token.manage');

CREATE TABLE permission_groups (
    id BINARY(16) NOT NULL PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    scope_kind ENUM('system','customer') NOT NULL,
    customer_id BINARY(16) NULL,
    form_id BINARY(16) NULL,
    revision BIGINT UNSIGNED NOT NULL,
    revoked_at DATETIME(6) NULL,
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK ((scope_kind='system' AND customer_id IS NULL AND form_id IS NULL) OR
           (scope_kind='customer' AND customer_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE permission_group_rights (
    group_id BINARY(16) NOT NULL,
    permission VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (group_id,permission),
    FOREIGN KEY (group_id) REFERENCES permission_groups(id),
    FOREIGN KEY (permission) REFERENCES permission_catalog(permission)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
-- Eine Zuweisung ist entweder Einzelrecht oder Gruppenmitgliedschaft.
-- Gruppen-/Zuweisungsschnittmenge und Befugnis des Vergebenden prueft der Dienst.
CREATE TABLE permission_assignments (
    id BINARY(16) NOT NULL PRIMARY KEY,
    account_id BINARY(16) NOT NULL,
    group_id BINARY(16) NULL,
    permission VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    scope_kind ENUM('system','customer') NOT NULL,
    customer_id BINARY(16) NULL,
    form_id BINARY(16) NULL,
    revision BIGINT UNSIGNED NOT NULL,
    granted_by BINARY(16) NOT NULL,
    granted_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    KEY ix_permission_subject (account_id,revoked_at),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    FOREIGN KEY (granted_by) REFERENCES accounts(id),
    FOREIGN KEY (group_id) REFERENCES permission_groups(id),
    FOREIGN KEY (permission) REFERENCES permission_catalog(permission),
    FOREIGN KEY (customer_id) REFERENCES customers(id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK ((group_id IS NULL) <> (permission IS NULL)),
    CHECK ((scope_kind='system' AND customer_id IS NULL AND form_id IS NULL) OR
           (scope_kind='customer' AND customer_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE api_hosts (
    id BINARY(16) NOT NULL PRIMARY KEY,
    host_ascii VARCHAR(253) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    enabled BOOLEAN NOT NULL,
    revision BIGINT UNSIGNED NOT NULL,
    UNIQUE KEY uq_api_host (host_ascii)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Domainzuordnung';
CREATE TABLE api_host_forms (
    api_host_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    -- ADR 0005 D1 (VORGESCHLAGEN): optionale Release-Bindung je (API-Host, Formular).
    -- release_id NULL = ungebunden (Auslieferung nach bisherigem Vertrag, keine neue Zusage).
    -- release_id gesetzt = gebunden: Auslieferung/Aufloesung ausschliesslich dieses Release,
    -- niemals forms.current_release_id. Wechsel = bestaetigte Aenderung, revision+1.
    release_id BINARY(16) NULL,
    binding_revision BIGINT UNSIGNED NOT NULL DEFAULT 1,
    changed_by BINARY(16) NULL,
    changed_at DATETIME(6) NULL,
    confirmation_audit_id BINARY(16) NULL COMMENT 'Audit-Beleg der menschlichen Bestaetigung dieser binding_revision',
    PRIMARY KEY (api_host_id,form_id),
    KEY ix_api_host_release (customer_id,form_id,release_id),
    FOREIGN KEY (api_host_id) REFERENCES api_hosts(id),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    FOREIGN KEY (customer_id,form_id,release_id) REFERENCES releases(customer_id,form_id,id),
    FOREIGN KEY (changed_by) REFERENCES accounts(id),
    CHECK (release_id IS NULL OR (changed_by IS NOT NULL AND changed_at IS NOT NULL AND confirmation_audit_id IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Domainzuordnung';
CREATE TABLE transport_replays (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    purpose ENUM('client-ua','client-ip','ed25519','transport') NOT NULL DEFAULT 'transport',
    key_version BIGINT UNSIGNED NOT NULL,
    request_id BINARY(16) NOT NULL,
    nonce BINARY(12) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    CHECK (purpose='transport'),
    PRIMARY KEY (form_id,key_version,request_id),
    UNIQUE KEY uq_transport_nonce (form_id,key_version,nonce),
    FOREIGN KEY (customer_id,form_id,purpose,key_version)
        REFERENCES form_protocol_keys(customer_id,form_id,purpose,generation_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';
CREATE TABLE legacy_adapter_bindings (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    adapter_identity VARCHAR(190) NOT NULL,
    -- R03 (VORGESCHLAGEN): Pin des mTLS-Clientzertifikats der Dienstidentitaet (SHA-256 ueber DER).
    service_cert_sha256 BINARY(32) NOT NULL,
    -- Runde 4 A6 (VORGESCHLAGEN): optionaler zweiter Pin fuer Zertifikatsrotation (beide gelten bis Promotion).
    service_cert_sha256_next BINARY(32) NULL,
    ua_secret_ref VARCHAR(255) NOT NULL,
    ip_secret_ref VARCHAR(255) NOT NULL,
    activated_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    UNIQUE KEY uq_adapter_binding_tenant (customer_id,form_id,id),
    UNIQUE KEY uq_adapter_identity_form (form_id,adapter_identity),
    FOREIGN KEY (customer_id,form_id) REFERENCES forms(customer_id,id),
    CHECK (expires_at>activated_at),
    CHECK (service_cert_sha256_next IS NULL OR service_cert_sha256_next<>service_cert_sha256)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';
-- Vertragsrunde 3 R03 (VORGESCHLAGEN): Signierregister des Adapters, getrennt von
-- form_protocol_keys(purpose='ed25519') = nativer SDK-Slot. Eigene Generation/Rotation/Widerruf.
-- Der native Pfad kennt diese Tabelle nicht; der Adapterpfad kennt form_protocol_keys nicht.
CREATE TABLE adapter_signers (
    binding_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    generation_no BIGINT UNSIGNED NOT NULL,
    public_key VARBINARY(32) NOT NULL,
    state ENUM('current','previous','revoked') NOT NULL,
    current_slot TINYINT GENERATED ALWAYS AS (CASE WHEN state='current' THEN 1 ELSE NULL END) PERSISTENT,
    valid_until DATETIME(6) NULL,
    created_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    PRIMARY KEY (binding_id,generation_no),
    UNIQUE KEY uq_adapter_signer_current (binding_id,current_slot),
    UNIQUE KEY uq_adapter_signer_key (binding_id,public_key),
    UNIQUE KEY uq_adapter_signer_pubkey (public_key), -- Runde 4 A5: Adapterschluessel global eindeutig (auch revoked)
    FOREIGN KEY (customer_id,form_id,binding_id) REFERENCES legacy_adapter_bindings(customer_id,form_id,id),
    CHECK (OCTET_LENGTH(public_key)=32),
    CHECK (state<>'previous' OR valid_until IS NOT NULL),
    CHECK (state<>'revoked' OR revoked_at IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';
-- Vertragsrunde 4 A1 (VORGESCHLAGEN): Replayregister des Adapterpfads. Schluessel = SHA-256 des
-- vollstaendigen signierten Texts (enthaelt Zeit, Idempotency-Key, bodyHash), nie Signaturbytes (A7).
-- Reservierung nach gueltiger Signatur; expires_at >= timestamp+300 s+60 s Toleranz und >= 600 s ab Reservierung.
CREATE TABLE adapter_replays (
    binding_id BINARY(16) NOT NULL,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    generation_no BIGINT UNSIGNED NOT NULL,
    text_sha256 BINARY(32) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    PRIMARY KEY (binding_id,text_sha256),
    KEY ix_adapter_replay_expiry (expires_at),
    FOREIGN KEY (binding_id,generation_no) REFERENCES adapter_signers(binding_id,generation_no),
    FOREIGN KEY (customer_id,form_id,binding_id) REFERENCES legacy_adapter_bindings(customer_id,form_id,id),
    CHECK (expires_at>=created_at + INTERVAL 600 SECOND)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Eingang';
-- Vertragsrunde 3: ein Eingangsnachweis bindet den akzeptierten Signierer (native SDK oder Adapter).
-- VORGESCHLAGEN, Spalten werden mit submissions/ingest_idempotency vom Eingangsbesitzer ergaenzt:
--   signer_kind ENUM('native','legacy-adapter','exception'), signer_generation_no, adapter_binding_id NULL.

CREATE TABLE workflow_resumptions (
    id BINARY(16) NOT NULL PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    run_id BINARY(16) NOT NULL,
    expected_revision BIGINT UNSIGNED NOT NULL,
    checkpoint_sha256 BINARY(32) NOT NULL,
    session_id BINARY(16) NOT NULL,
    confirmed_by BINARY(16) NOT NULL,
    confirmed_at DATETIME(6) NOT NULL,
    consumed_at DATETIME(6) NOT NULL,
    UNIQUE KEY uq_resume_revision (run_id,expected_revision),
    FOREIGN KEY (customer_id,form_id,run_id) REFERENCES workflow_runs(customer_id,form_id,id),
    FOREIGN KEY (session_id) REFERENCES sessions(id),
    FOREIGN KEY (confirmed_by) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Ablaufengine';
-- Historische Formate NICHT als neue Hashalgorithmen erfinden; Bezeichner erst
-- nach Hash-/Formatpruefung belegen. (ADR 0005 D4: Altcredentials werden nicht uebernommen.)
CREATE TABLE oauth_clients (
    id BINARY(16) NOT NULL PRIMARY KEY,
    client_identifier VARCHAR(255) NOT NULL,
    name VARCHAR(255) NOT NULL,
    redirect_uris_json JSON NOT NULL,
    created_at DATETIME(6) NULL,
    last_used_at DATETIME(6) NULL,
    origin ENUM('native') NOT NULL,
    UNIQUE KEY uq_oauth_client (client_identifier)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE oauth_grants (
    id BINARY(16) NOT NULL PRIMARY KEY,
    client_id BINARY(16) NOT NULL,
    account_id BINARY(16) NOT NULL,
    scopes_json JSON NOT NULL,
    resource VARCHAR(512) NOT NULL,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    origin ENUM('native') NOT NULL,
    FOREIGN KEY (client_id) REFERENCES oauth_clients(id),
    FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE mcp_tokens (
    id BINARY(16) NOT NULL PRIMARY KEY,
    account_id BINARY(16) NOT NULL,
    grant_id BINARY(16) NULL,
    token_hash VARBINARY(255) NOT NULL,
    hash_format VARCHAR(64) NOT NULL,
    label VARCHAR(255) NULL,
    scopes_json JSON NOT NULL,
    scope_json JSON NOT NULL,
    created_at DATETIME(6) NULL,
    last_used_at DATETIME(6) NULL,
    expires_at DATETIME(6) NOT NULL,
    revoked_at DATETIME(6) NULL,
    origin ENUM('native') NOT NULL,
    UNIQUE KEY uq_mcp_token_hash (hash_format,token_hash),
    FOREIGN KEY (account_id) REFERENCES accounts(id),
    FOREIGN KEY (grant_id) REFERENCES oauth_grants(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE oauth_codes (
    id BINARY(16) NOT NULL PRIMARY KEY,
    code_hash VARBINARY(255) NOT NULL,
    hash_format VARCHAR(64) NOT NULL,
    grant_id BINARY(16) NOT NULL,
    redirect_uri VARCHAR(512) NOT NULL,
    code_challenge VARCHAR(255) NOT NULL,
    challenge_method VARCHAR(32) NOT NULL,
    resource VARCHAR(512) NOT NULL,
    scopes_json JSON NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    consumed_at DATETIME(6) NULL,
    origin ENUM('native') NOT NULL,
    UNIQUE KEY uq_oauth_code (hash_format,code_hash),
    FOREIGN KEY (grant_id) REFERENCES oauth_grants(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';
CREATE TABLE oauth_refresh_tokens (
    id BINARY(16) NOT NULL PRIMARY KEY,
    grant_id BINARY(16) NOT NULL,
    refresh_hash VARBINARY(255) NOT NULL,
    hash_format VARCHAR(64) NOT NULL,
    family_id BINARY(16) NOT NULL,
    replaced_by BINARY(16) NULL,
    created_at DATETIME(6) NOT NULL,
    expires_at DATETIME(6) NOT NULL,
    replaced_at DATETIME(6) NULL,
    revoked_at DATETIME(6) NULL,
    origin ENUM('native') NOT NULL,
    UNIQUE KEY uq_oauth_refresh (hash_format,refresh_hash),
    FOREIGN KEY (grant_id) REFERENCES oauth_grants(id),
    FOREIGN KEY (replaced_by) REFERENCES oauth_refresh_tokens(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Kunden und Rechte';

-- Resendmanifest ist selbst ein verschluesseltes :2-Objekt im Gesamtinventar.
-- Keine Klartextempfaenger/-vorlagen in diesen Spalten.
ALTER TABLE submissions
    ADD COLUMN mail_manifest_object_id BINARY(16) NULL,
    -- Runde 4 M1 (VORGESCHLAGEN): Pin auf die unveraenderliche Nutzdatenidentitaet des Manifestobjekts,
    -- im selben Commit wie mail_manifest_object_id gesetzt (FK siehe unten, nach stored_objects.payload_sha256).
    ADD COLUMN mail_manifest_payload_sha256 BINARY(32) NULL,
    ADD COLUMN source_submission_id BINARY(16) NULL,
    ADD CONSTRAINT fk_submission_manifest FOREIGN KEY (customer_id,form_id,mail_manifest_object_id)
        REFERENCES stored_objects(customer_id,form_id,id),
    ADD CONSTRAINT fk_submission_source FOREIGN KEY (customer_id,form_id,source_submission_id)
        REFERENCES submissions(customer_id,form_id,id),
    ADD CONSTRAINT ck_submission_manifest_pin CHECK ((mail_manifest_object_id IS NULL) = (mail_manifest_payload_sha256 IS NULL));

-- ===== Vertragsrunde 3, 28.10.2026: neue technische Strukturen VORGESCHLAGEN, nicht ausgefuehrt. =====
-- R07: unveraenderliche Nutzdatenidentitaet = SHA-256(iv||ct||tag) des Nutzchiffrats (paket-v2.md).
-- Sie bleibt bei Rewrap/Hold/Rotation gleich (nur Wrap-Segmente aendern sich); packet_sha256
-- (ciphertext_sha256) und revision bezeichnen dagegen die aktuelle Huelle und aendern sich.
ALTER TABLE stored_objects
    ADD COLUMN payload_sha256 BINARY(32) NOT NULL AFTER ciphertext_sha256;

-- Runde 4 M1: Manifestpin als zusammengesetzter FK. payload_sha256 ist rewrap-invariant (kein ON UPDATE noetig).
-- Grenze (M2): schuetzt gegen Zeigerfehler/Korruption, NICHT gegen einen DB-Schreiber, der beide Seiten aendert.
-- Zusaetzlich in der Anwendung zu pruefen: stored_objects.submission_id = submissions.id und object_role='mail-manifest'.
ALTER TABLE stored_objects
    ADD UNIQUE KEY uq_stored_object_payload (customer_id,form_id,id,payload_sha256);
ALTER TABLE submissions
    ADD CONSTRAINT fk_submission_manifest_pin FOREIGN KEY (customer_id,form_id,mail_manifest_object_id,mail_manifest_payload_sha256)
        REFERENCES stored_objects(customer_id,form_id,id,payload_sha256);

-- R07: Manifestformat siehe resend-manifest.schema.json; Objektbezuege nur ueber objectId + payloadSha256.
-- ADR 0005 D4: OAuth/MCP-Altcredentials werden NICHT uebernommen (Neuanmeldung).
-- Kein Legacy-Resourceprofil, origin der OAuth-/MCP-Tabellen nur 'native', family_id NOT NULL, kein Import von
-- Codes/Grants/Refresh-Tokens. Neue Credentials binden die Resource strikt (resource NOT NULL).
ALTER TABLE oauth_codes
    ADD COLUMN revoked_at DATETIME(6) NULL;

-- M04 / ADR 0005 D7 (VORGESCHLAGEN): aggregierbare, inhaltsfreie Praesenzflags fuer die Bestands-Ads-Sicht.
-- Werte (GCLID/UA und, falls der Dump sie enthaelt, IP-Bezuege) bleiben ausschliesslich im
-- verschluesselten metadata_object_id-Objekt (geschuetzte Huelle, Zugriff statistics.read+content.decrypt).
-- Keine Klartextspalte fuer IP-Werte; keine Auswertung auf Personenebene; Herkunft immer 'legacy'.
ALTER TABLE legacy_statistics
    ADD COLUMN has_gclid BOOLEAN NOT NULL DEFAULT 0,
    ADD COLUMN has_user_agent BOOLEAN NOT NULL DEFAULT 0,
    ADD COLUMN has_ip_reference BOOLEAN NOT NULL DEFAULT 0;

-- P11-F: review-only conversion artifacts; no domain binding or mail assignment.
CREATE TABLE migration_form_drafts (
    form_id BINARY(16) NOT NULL PRIMARY KEY,
    draft_id BINARY(16) NOT NULL,
    report_json JSON NOT NULL,
    proposals_json JSON NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (form_id) REFERENCES forms(id),
    FOREIGN KEY (draft_id) REFERENCES form_drafts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;

-- ADR 0026: form-owned SecretStore reference and expiring pseudonymous abuse counters.
CREATE TABLE form_abuse_secrets (
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    secret_ref VARCHAR(80) NOT NULL,
    PRIMARY KEY (form_id),
    FOREIGN KEY (customer_id, form_id) REFERENCES forms(customer_id, id) ON DELETE CASCADE
) ENGINE=InnoDB;
CREATE TABLE ingest_abuse_ips (
    form_id BINARY(16) NOT NULL,
    ip_digest BINARY(32) NOT NULL,
    hits INT UNSIGNED NOT NULL,
    window_start DATETIME(6) NOT NULL,
    blocked_until DATETIME(6) NULL,
    PRIMARY KEY (form_id, ip_digest),
    INDEX ix_abuse_expiry (window_start, blocked_until),
    FOREIGN KEY (form_id) REFERENCES forms(id) ON DELETE CASCADE
-- P11-C/D: immutable plans and encrypted source references. No source values in reports.
CREATE TABLE migration_jobs (
 id BINARY(16) PRIMARY KEY,
 actor_id BINARY(16) NOT NULL,
 source_json JSON NOT NULL,
 plan_json JSON NOT NULL,
 expected_schema CHAR(64) NOT NULL,
 state VARCHAR(32) NOT NULL,
 phase VARCHAR(32) NOT NULL,
 dry_run BOOLEAN NOT NULL,
 cancel_requested BOOLEAN NOT NULL DEFAULT 0,
 report_json JSON NOT NULL,
 error_code VARCHAR(32) NULL,
 probe_hash CHAR(64) NULL,
 test_hash CHAR(64) NULL,
 created_at DATETIME(6) NOT NULL,
 updated_at DATETIME(6) NOT NULL,
 INDEX ix_migration_job_state (state, created_at)
) ENGINE=InnoDB;
