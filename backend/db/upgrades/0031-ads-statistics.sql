-- Ungeprüfter Bestandsupgrade-Kandidat; nicht automatisch ausführen.
-- P13-Ads: nullable = not measured; no raw click, IP or user-agent values.
ALTER TABLE statistics_events
    ADD COLUMN ads_present BOOLEAN NULL DEFAULT NULL;
