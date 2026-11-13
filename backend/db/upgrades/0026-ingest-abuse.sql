-- SPDX-License-Identifier: AGPL-3.0-only
-- Separately reviewed upgrade; do not change recorded baseline checksums.
ALTER TABLE submissions ADD COLUMN captcha_status VARCHAR(32) NOT NULL DEFAULT 'disabled';

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
) ENGINE=InnoDB;
