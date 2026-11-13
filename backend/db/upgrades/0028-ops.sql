-- SPDX-License-Identifier: AGPL-3.0-only
-- ADR 0026: safe finite event vocabulary, no payloads, addresses or transport errors.
CREATE TABLE ops_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    customer_id BINARY(16) NOT NULL,
    form_id BINARY(16) NOT NULL,
    submission_id BINARY(16) NULL,
    source_id BINARY(16) NOT NULL,
    target_id BINARY(16) NULL,
    event ENUM('pending','sending','accepted','failed','uncertain','recovered') NOT NULL,
    operation ENUM('mail','webhook','scanner','storage','sdk') NOT NULL,
    priority TINYINT UNSIGNED NOT NULL,
    alarm_seen BOOLEAN NOT NULL DEFAULT 0,
    occurred_at DATETIME(6) NOT NULL,
    KEY ix_ops_scope (customer_id,form_id,id),
    KEY ix_ops_time (occurred_at),
    KEY ix_ops_alarm (alarm_seen,id),
    KEY ix_ops_submission (submission_id,id),
    KEY ix_ops_source (source_id,operation,id),
    CHECK (priority <= 2)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
CREATE TABLE ops_alarm_state (
    singleton TINYINT NOT NULL PRIMARY KEY,
    last_sent_at DATETIME(6) NULL,
    suppressed BIGINT UNSIGNED NOT NULL DEFAULT 0,
    suppressed_priority TINYINT UNSIGNED NOT NULL DEFAULT 0,
    outcome ENUM('idle','claimed','accepted','failed') NOT NULL DEFAULT 'idle',
    CHECK (singleton = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin;
INSERT INTO ops_alarm_state (singleton) VALUES (1);
-- Pin the selected transport connection for the whole attempt, including asynchronous completion.
ALTER TABLE mail_deliveries ADD COLUMN ops_connection_id BINARY(16) NULL;
CREATE TRIGGER ops_mail_pin_insert BEFORE INSERT ON mail_deliveries FOR EACH ROW
SET NEW.ops_connection_id=(SELECT connection_id FROM form_connections WHERE customer_id=NEW.customer_id AND form_id=NEW.form_id AND purpose='mail' AND environment='production' LIMIT 1);
CREATE TRIGGER ops_mail_pin_update BEFORE UPDATE ON mail_deliveries FOR EACH ROW
SET NEW.ops_connection_id=CASE WHEN NEW.state='leased' AND OLD.state<>'leased' THEN (SELECT connection_id FROM form_connections WHERE customer_id=NEW.customer_id AND form_id=NEW.form_id AND purpose='mail' AND environment='production' LIMIT 1) ELSE OLD.ops_connection_id END;
CREATE TRIGGER ops_mail_insert AFTER INSERT ON mail_deliveries FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.ops_connection_id,
 CASE WHEN NEW.state='smtp-accepted' THEN 'accepted' WHEN NEW.state IN ('waiting-manual','abandoned') THEN 'failed' WHEN NEW.state='uncertain' THEN 'uncertain' WHEN NEW.state='leased' THEN 'sending' ELSE 'pending' END,
 'mail', CASE WHEN NEW.state='uncertain' THEN 2 WHEN NEW.state IN ('waiting-manual','abandoned') THEN 1 ELSE 0 END, UTC_TIMESTAMP(6)
WHERE NEW.environment='production';
CREATE TRIGGER ops_mail_update AFTER UPDATE ON mail_deliveries FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.ops_connection_id,
 CASE WHEN NEW.state='smtp-accepted' THEN 'accepted' WHEN NEW.state IN ('waiting-manual','abandoned') THEN 'failed' WHEN NEW.state='uncertain' THEN 'uncertain' WHEN NEW.state='leased' THEN 'sending' ELSE 'pending' END,
 'mail', CASE WHEN NEW.state='uncertain' THEN 2 WHEN NEW.state IN ('waiting-manual','abandoned') THEN 1 ELSE 0 END, UTC_TIMESTAMP(6)
WHERE NEW.environment='production' AND (NOT (NEW.state <=> OLD.state) OR NEW.attempts <> OLD.attempts);
CREATE TRIGGER ops_webhook_insert AFTER INSERT ON webhook_outbox FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.webhook_id,
 CASE WHEN NEW.state='succeeded' THEN 'accepted' WHEN NEW.state IN ('failed-terminal') THEN 'failed' WHEN NEW.state='uncertain' THEN 'uncertain' WHEN NEW.state='leased' THEN 'sending' ELSE 'pending' END,
 'webhook', CASE WHEN NEW.state='uncertain' THEN 2 WHEN NEW.state IN ('failed-terminal') THEN 1 ELSE 0 END, UTC_TIMESTAMP(6)
WHERE 1=1;
CREATE TRIGGER ops_webhook_update AFTER UPDATE ON webhook_outbox FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.webhook_id,
 CASE WHEN NEW.state='succeeded' THEN 'accepted' WHEN NEW.state IN ('failed-terminal') THEN 'failed' WHEN NEW.state='uncertain' THEN 'uncertain' WHEN NEW.state='leased' THEN 'sending' ELSE 'pending' END,
 'webhook', CASE WHEN NEW.state='uncertain' THEN 2 WHEN NEW.state IN ('failed-terminal') THEN 1 ELSE 0 END, UTC_TIMESTAMP(6)
WHERE (NOT (NEW.state <=> OLD.state) OR NEW.attempts <> OLD.attempts);
CREATE TRIGGER ops_scanner_insert AFTER INSERT ON submissions FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.id,NEW.id,
 CASE WHEN NEW.malware_scan_status='clean' THEN 'recovered' ELSE 'failed' END,
 'scanner', CASE WHEN NEW.malware_scan_status='clean' THEN 0 ELSE 2 END, UTC_TIMESTAMP(6) WHERE NEW.environment='production' AND NEW.malware_scan_status IN ('infected','error','failed','blocked');
CREATE TRIGGER ops_scanner_update AFTER UPDATE ON submissions FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.id,NEW.id,
 CASE WHEN NEW.malware_scan_status='clean' THEN 'recovered' ELSE 'failed' END,
 'scanner', CASE WHEN NEW.malware_scan_status='clean' THEN 0 ELSE 2 END, UTC_TIMESTAMP(6) WHERE NEW.environment='production' AND NOT (NEW.malware_scan_status <=> OLD.malware_scan_status) AND NEW.malware_scan_status IN ('clean','infected','error','failed','blocked');
CREATE TRIGGER ops_storage_insert AFTER INSERT ON stored_objects FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.connection_id,
 CASE WHEN NEW.state='failed' THEN 'failed' ELSE 'recovered' END,'storage',CASE WHEN NEW.state='failed' THEN 2 ELSE 0 END,UTC_TIMESTAMP(6) WHERE NEW.state='failed';
CREATE TRIGGER ops_storage_update AFTER UPDATE ON stored_objects FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,submission_id,source_id,target_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.submission_id,NEW.id,NEW.connection_id,
 CASE WHEN NEW.state='failed' THEN 'failed' ELSE 'recovered' END,'storage',CASE WHEN NEW.state='failed' THEN 2 ELSE 0 END,UTC_TIMESTAMP(6) WHERE (NEW.state='failed' OR (OLD.state='failed' AND NEW.state='ready')) AND NOT (NEW.state <=> OLD.state);
CREATE TRIGGER ops_sdk_insert AFTER INSERT ON sdk_deployments FOR EACH ROW
    INSERT INTO ops_events (customer_id,form_id,source_id,event,operation,priority,occurred_at)
SELECT NEW.customer_id,NEW.form_id,NEW.form_id,CASE WHEN NEW.result='failed' THEN 'failed' ELSE 'recovered' END,'sdk',CASE WHEN NEW.result='failed' THEN 1 ELSE 0 END,NEW.finished_at;
