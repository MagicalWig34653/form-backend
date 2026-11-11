// SPDX-License-Identifier: AGPL-3.0-only
export const migrationStates: Record<string, string> = {
  queued: 'Wartet auf Freigabe des Workers',
  running: 'Läuft',
  paused: 'Pausiert',
  failed: 'Fehlgeschlagen',
  review: 'Wartet auf Prüfung',
  closed: 'Altzugriff entfernt',
};
// The import plan is built from the source check: see buildPlan in lib/admin/migrationFlow.ts (ADR 0040).
