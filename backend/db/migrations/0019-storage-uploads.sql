-- SPDX-License-Identifier: AGPL-3.0-only
-- ADR 0019, additive migration for an existing baseline. Execute only as an explicitly planned upgrade.
-- Never run concurrently with ingest/worker code requiring this table before it exists.
CREATE TABLE storage_uploads (
    object_id BINARY(16) NOT NULL PRIMARY KEY,
    ciphertext LONGBLOB NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (object_id) REFERENCES stored_objects(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin COMMENT='owner: Speicher; ADR 0019';
