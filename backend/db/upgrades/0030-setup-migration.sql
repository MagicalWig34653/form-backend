-- Ungeprüfter Bestandsupgrade-Kandidat; nicht automatisch ausführen.
INSERT IGNORE INTO permission_catalog(permission) VALUES ('migration.run');

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
 created_at DATETIME(6) NOT NULL,
 updated_at DATETIME(6) NOT NULL,
 INDEX ix_migration_job_state (state, created_at)
) ENGINE=InnoDB;
