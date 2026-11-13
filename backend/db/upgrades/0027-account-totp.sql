-- SPDX-License-Identifier: AGPL-3.0-only
-- Konten: encrypted references only, account-wide lockout and replay counter.
CREATE TABLE account_totp (
    account_id BINARY(16) NOT NULL PRIMARY KEY,
    secret_ref VARCHAR(255) NULL,
    pending_ref VARCHAR(255) NULL,
    pending_until DATETIME(6) NULL,
    last_step BIGINT NOT NULL DEFAULT -1,
    failures INT NOT NULL DEFAULT 0,
    locked_until DATETIME(6) NULL,
    FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
