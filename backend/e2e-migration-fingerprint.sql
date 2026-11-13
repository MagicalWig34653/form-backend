-- SPDX-License-Identifier: AGPL-3.0-only
-- Content fingerprint of a migration target without random ids (shared by e2e-migration-restart.sh and e2e-migration-cli.sh).
SET SESSION group_concat_max_len = 1000000000;
SELECT 'customers', COUNT(*), MD5(GROUP_CONCAT(name ORDER BY name)) FROM customers;
SELECT 'forms', COUNT(*), MD5(GROUP_CONCAT(CONCAT_WS('|',name,active) ORDER BY name)) FROM forms;
SELECT 'form_versions', COUNT(*) FROM form_versions;
SELECT 'generations', COUNT(*), MD5(GROUP_CONCAT(CONCAT_WS('|',generation_no,state) ORDER BY generation_no,state)) FROM customer_key_generations;
SELECT 'recovery', COUNT(*) FROM data_key_recovery;
SELECT 'connections', COUNT(*) FROM connections;
SELECT 'webhooks', COUNT(*) FROM webhook_endpoints;
SELECT 'idempotency', COUNT(*) FROM ingest_idempotency;
SELECT 'submissions', COUNT(*), MD5(GROUP_CONCAT(CONCAT_WS('|',received_at,state,environment,removable,malware_scan_status,legacy_sent_server) ORDER BY received_at,state,legacy_sent_server)) FROM submissions;
SELECT 'objects', COUNT(*), MD5(GROUP_CONCAT(CONCAT_WS('|',object_role,ordinal_no,HEX(ciphertext_sha256),byte_count,state,kid,wrap_kind) ORDER BY object_role,ordinal_no,ciphertext_sha256,kid)) FROM stored_objects;
SELECT 'ledger', source_table, COUNT(*), MD5(GROUP_CONCAT(HEX(source_key) ORDER BY source_key)) FROM migration_objects GROUP BY source_table;
SELECT 'issues', issue_code, COUNT(DISTINCT source_table, source_key) FROM migration_issues WHERE state='open' GROUP BY issue_code;
