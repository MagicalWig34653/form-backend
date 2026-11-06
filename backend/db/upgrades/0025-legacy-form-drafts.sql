-- SPDX-License-Identifier: AGPL-3.0-only
-- P11-F upgrade candidate: review and test in MariaDB before existing installations use it.
-- Never rewrite the already recorded baseline checksum. No production execution in this package.
CREATE TABLE migration_form_drafts (
    form_id BINARY(16) NOT NULL PRIMARY KEY,
    draft_id BINARY(16) NOT NULL,
    report_json JSON NOT NULL,
    proposals_json JSON NOT NULL,
    created_at DATETIME(6) NOT NULL,
    FOREIGN KEY (form_id) REFERENCES forms(id),
    FOREIGN KEY (draft_id) REFERENCES form_drafts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
