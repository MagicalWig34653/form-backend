-- SPDX-License-Identifier: AGPL-3.0-only
-- ADR 0045 (Opus-Security-Pruefung, API-Hosts): jeder API-Host hat einen Eigentuemer-Kunden. Nur der Eigentuemer (oder system.manage)
-- haengt Formulare an, schaltet ein/aus; fuer Fremde sind Hosts nicht erkennbar (404).
-- Idempotent (ADD COLUMN IF NOT EXISTS, Zuordnung nur fuer Hosts ohne Eigentuemer).
ALTER TABLE api_hosts ADD COLUMN IF NOT EXISTS owner_customer_id BINARY(16) NULL;
-- Zuordnung bestehender Hosts: 1) Kunde des aeltesten Audit-Ereignisses domain.api.configure dieses Hosts (= Ersteller),
-- 2) sonst Kunde der aeltesten Formularbindung (changed_at, dann binding_revision, dann customer_id; mehrdeutig, wenn mehrere
-- Kunden gebunden sind: der aelteste gewinnt), 3) sonst bleibt der Host ohne Eigentuemer (dann nur system.manage).
UPDATE api_hosts h SET h.owner_customer_id = COALESCE(
  (SELECT a.customer_id FROM audit_events a WHERE a.subject_id = h.id AND a.action_code = 'domain.api.configure' AND a.customer_id IS NOT NULL ORDER BY a.occurred_at, a.id LIMIT 1),
  (SELECT f.customer_id FROM api_host_forms f WHERE f.api_host_id = h.id ORDER BY f.changed_at IS NULL, f.changed_at, f.binding_revision, f.customer_id LIMIT 1))
WHERE h.owner_customer_id IS NULL;
