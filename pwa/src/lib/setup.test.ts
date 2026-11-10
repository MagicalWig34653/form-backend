import { describe, expect, it } from 'vitest';
import { createImportPlan, migrationStates } from './setup';
const customer = '33333333-3333-4333-8333-333333333333';
const form = '11111111-1111-4111-8111-111111111111';
describe('Einrichtung und Umstieg', () => {
  it('erzeugt explizite Zuordnung mit Snapshotkennung und ohne Zugangsdaten', () => {
    const plan = createImportPlan(customer, 'Synthetisch', form, 'snapshot', 'a'.repeat(64));
    expect(plan.formCustomers).toEqual({ [form]: customer });
    expect(plan.dumpSHA256).toBe('a'.repeat(64));
    expect(JSON.stringify(plan)).not.toMatch(/password|host|username/);
  });
  it('blockiert fehlende oder ungültige Zuordnungen', () => {
    for (const ids of ['', '../invalid', 'foo'])
      expect(() => createImportPlan(customer, 'Test', ids, 'snapshot', 'a'.repeat(64))).toThrow();
    expect(() => createImportPlan(customer, '', form, 'snapshot', 'a'.repeat(64))).toThrow();
  });
  it('verwechselt Prüfung nicht mit Umschaltung', () => {
    expect(migrationStates.review).toBe('Wartet auf Prüfung');
    expect(migrationStates.paused).toBe('Pausiert');
    expect(migrationStates.failed).toBe('Fehlgeschlagen');
  });
});
