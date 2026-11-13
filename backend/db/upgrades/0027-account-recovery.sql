-- SPDX-License-Identifier: AGPL-3.0-only
CREATE TABLE account_key_recovery (
 account_id BINARY(16) NOT NULL PRIMARY KEY,
 revision CHAR(36) NOT NULL,
 salt BINARY(32) NOT NULL,
 iv BINARY(12) NOT NULL,
 wrapped_key BINARY(48) NOT NULL,
 CONSTRAINT fk_account_recovery FOREIGN KEY (account_id) REFERENCES account_keys(account_id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
CREATE TABLE key_rotation_requests (
 customer_id BINARY(16) NOT NULL PRIMARY KEY,
 CONSTRAINT fk_rotation_request FOREIGN KEY (customer_id) REFERENCES customers(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
