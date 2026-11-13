-- SPDX-License-Identifier: AGPL-3.0-only
-- ADR 0042 (Review Astra 2 M1/M2): Zielrevision und persistierter Laufzustand des SDK-Selbstupdates.
-- Wird von `migrate` nach schema-p3 angewendet (MigrationRunner.upgrades). Idempotent: auch nach einem
-- abgebrochenen oder manuell vorgezogenen Lauf wiederholbar (ADD COLUMN IF NOT EXISTS, MariaDB).
ALTER TABLE sdk_targets
 ADD COLUMN IF NOT EXISTS target_revision INT UNSIGNED NOT NULL DEFAULT 1 AFTER last_result,
 ADD COLUMN IF NOT EXISTS run_phase VARCHAR(20) CHARACTER SET ascii COLLATE ascii_bin NULL AFTER target_revision,
 ADD COLUMN IF NOT EXISTS run_action ENUM('install','rollback') NULL AFTER run_phase,
 ADD COLUMN IF NOT EXISTS run_trigger ENUM('manual','auto') NULL AFTER run_action,
 ADD COLUMN IF NOT EXISTS run_started_at DATETIME(6) NULL AFTER run_trigger;
