-- SPDX-License-Identifier: AGPL-3.0-only
-- QA 13.11. (Datenvernichtung): Importierte Einsendungen (release_evidence = 'legacy-unknown') tragen keine Faelligkeit. Der Altbackend-
-- Dump hat keine Frist; die Standardfrist (3 Tage) haette Monate alte Altdaten sofort faellig gemacht, der Aufbewahrungsjob (er
-- ueberspringt NULL) haette sie nach dem Import geloescht. Die Frist fuer importierte Einsendungen setzt der Betreiber ausdruecklich
-- (PUT .../retention mit applyToImported).
-- Dieses Upgrade setzt die Faelligkeit bereits importierter, noch vorhandener Einsendungen zurueck. Idempotent. Es laeuft nach
-- 0034 (das fehlende Faelligkeiten fuellt) genau einmal je Datenbank. Eine Faelligkeit, die der Betreiber vorher ausdruecklich
-- gesetzt hat, ist von der automatisch gesetzten nicht unterscheidbar; Datenschutz schliesst hier Zerstoerung aus, daher immer NULL.
-- Der Betreiber setzt die Frist danach bewusst neu.
UPDATE submissions SET retention_due_at = NULL WHERE release_evidence = 'legacy-unknown' AND retention_due_at IS NOT NULL;
