-- SPDX-License-Identifier: AGPL-3.0-only
-- P11-B upgrade candidate, requires MariaDB review/test before use on existing installations.
-- No production execution by P11-B. Baseline checksum must not be rewritten.
-- No automatic grants: an operator must explicitly assign system.settings at system scope
-- to approved accounts/groups using the established permission assignment process.
INSERT IGNORE INTO permission_catalog (permission) VALUES ('system.settings');
