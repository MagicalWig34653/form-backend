-- SPDX-License-Identifier: AGPL-3.0-only
-- ADR 0012 Nr. 2: Aufbewahrungsfrist ist Pflicht, Standard 72 Stunden = 3 Tage (`retention.days` in Tagen).
-- Wird von `migrate` nach schema-p3 angewendet (MigrationRunner.upgrades). Idempotent: INSERT IGNORE legt nur Fehlendes an
-- und bestehende Fristen bleiben unberuehrt; der UPDATE trifft nur Einsendungen ohne Faelligkeit.
-- ACHTUNG: Einsendungen aelter als die Frist sind danach sofort faellig (der Aufbewahrungsjob loescht sie beim naechsten Lauf,
-- ausser gehaltene Eintraege und importierte Eintraege eines noch fortsetzbaren Imports).

-- 1. Jedes Formular ohne Eintrag bekommt die Standardfrist (scope_key = form:<uuid kleingeschrieben>).
INSERT IGNORE INTO settings (scope_key, setting_key, safe_value_json, manageable, modified_at)
SELECT CONCAT('form:', LOWER(CONCAT(SUBSTR(HEX(f.id), 1, 8), '-', SUBSTR(HEX(f.id), 9, 4), '-', SUBSTR(HEX(f.id), 13, 4), '-',
         SUBSTR(HEX(f.id), 17, 4), '-', SUBSTR(HEX(f.id), 21, 12)))), 'retention.days', '3', 1, UTC_TIMESTAMP(6)
FROM forms f;

-- 2. Einsendungen ohne Faelligkeit: Empfangszeit (sonst jetzt) plus Formularfrist.
UPDATE submissions s
LEFT JOIN settings st
  ON st.setting_key = 'retention.days'
 AND st.scope_key = CONCAT('form:', LOWER(CONCAT(SUBSTR(HEX(s.form_id), 1, 8), '-', SUBSTR(HEX(s.form_id), 9, 4), '-', SUBSTR(HEX(s.form_id), 13, 4), '-',
         SUBSTR(HEX(s.form_id), 17, 4), '-', SUBSTR(HEX(s.form_id), 21, 12))))
SET s.retention_due_at = DATE_ADD(COALESCE(s.received_at, UTC_TIMESTAMP(6)), INTERVAL COALESCE(CAST(JSON_VALUE(st.safe_value_json, '$') AS UNSIGNED), 3) DAY)
WHERE s.retention_due_at IS NULL;
