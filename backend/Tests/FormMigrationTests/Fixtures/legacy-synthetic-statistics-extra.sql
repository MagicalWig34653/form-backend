-- SPDX-License-Identifier: AGPL-3.0-only
-- Additional SYNTHETIC statistics rows (all values invented) for backend/e2e-migration-cli.sh; load after legacy-real.sql + legacy-synthetic.sql.
-- Unique markers (gclid, user agent, domain, IPv4, IPv6) that must never appear in clear text in a target dump.
INSERT INTO `statistics` (`ID`,`UUID`,`timestamp`,`formularUUID`,`status`,`type`,`gclid`,`userAgent`,`domain`) VALUES
(101,'5a7a0000-0000-4000-8000-000000000101','2026-05-06 09:00:00','11111111-1111-4111-8111-111111111111','SUCCESS','ANFRAGE','synthetic-gclid-AbC123','SyntheticAgent/9.9 (Probe)','stat-probe.example.invalid'),
(102,'5a7a0000-0000-4000-8000-000000000102','2026-05-06 09:01:00','22222222-2222-4222-8222-222222222222','SUSPICIOUS','VISIT',NULL,NULL,'203.0.113.77'),
(103,'5a7a0000-0000-4000-8000-000000000103','2026-05-06 09:02:00','33333333-3333-4333-8333-333333333333','GENERIC_ERROR',NULL,NULL,'SyntheticAgent/2001:db8::7',NULL);
