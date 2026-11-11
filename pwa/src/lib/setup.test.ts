import { describe, expect, it } from 'vitest';
import { migrationStates } from './setup';
import { assignForms, buildPlan } from './admin/migrationFlow';
const customer = '33333333-3333-4333-8333-333333333333';
const form = '11111111-1111-4111-8111-111111111111';
describe('Einrichtung und Umstieg', () => {
  it('erzeugt explizite Zuordnung mit Snapshotkennung und ohne Zugangsdaten', () => {
    const customers = [{ id: customer, name: 'Synthetisch' }];
    const { plan } = buildPlan({
      namespace: 'snapshot',
      snapshot: 'a'.repeat(64),
      customers,
      formCustomers: assignForms([form], customers, {}),
      connectionCustomers: {},
      keys: [],
      keyCustomers: {},
      extra: '{}',
    });
    expect(plan.formCustomers).toEqual({ [form]: customer });
    expect(plan.dumpSHA256).toBe('a'.repeat(64));
    expect(JSON.stringify(plan)).not.toMatch(/password|host|username/);
  });
  it('verwechselt Prüfung nicht mit Umschaltung', () => {
    expect(migrationStates.review).toBe('Wartet auf Prüfung');
    expect(migrationStates.paused).toBe('Pausiert');
    expect(migrationStates.failed).toBe('Fehlgeschlagen');
  });
});
