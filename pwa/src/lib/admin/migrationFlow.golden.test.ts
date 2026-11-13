import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  assignConnections,
  assignForms,
  assignKeys,
  buildPlan,
  keyWarnings,
  mappingIssues,
  snapshotOf,
  sourceConnections,
  sourceForms,
  suggestNamespace,
  type PlanCustomer,
  type SourceInventory,
} from './migrationFlow';

// Shared with the backend test ImportRehearsalTests: the inventory is what POST /migration/test returns for
// the synthetic legacy source, the plan is what the PWA must build from it.
const golden = JSON.parse(
  readFileSync(resolve(process.cwd(), '../contracts/migration/rehearsal-golden.json'), 'utf8'),
) as {
  source: { host: string; database: string };
  customers: PlanCustomer[];
  formChoice: Record<string, string>;
  inventory: SourceInventory;
  plan: Record<string, unknown>;
};

describe('Golden-Plan der Generalprobe', () => {
  it('baut aus der Backend-Antwort genau den Plan, den das Backend im Test erwartet', async () => {
    const inv = golden.inventory;
    const forms = sourceForms(inv);
    const connections = sourceConnections(inv);
    const formCustomers = assignForms(
      forms.map((f) => f.id),
      golden.customers,
      golden.formChoice,
    );
    const keys = inv.keys ?? [];
    const usage = inv.keyUsage?.items ?? [];
    const { plan, extraValid } = buildPlan({
      namespace: suggestNamespace(golden.source.host, golden.source.database),
      snapshot: await snapshotOf(inv),
      customers: golden.customers,
      formCustomers,
      connectionCustomers: assignConnections(
        connections,
        forms,
        formCustomers,
        golden.customers,
        {},
      ),
      keys,
      keyCustomers: assignKeys(keys, usage, formCustomers, golden.customers, {}),
      extra: '{}',
    });
    expect(extraValid).toBe(true);
    const { dumpSHA256, ...rest } = plan;
    expect(dumpSHA256).toMatch(/^[0-9a-f]{64}$/);
    expect(rest).toEqual(golden.plan);
    // Complete and without warnings: the run can start.
    expect(
      mappingIssues({
        plan,
        extraValid,
        formIds: forms.map((f) => f.id),
        connectionIds: connections.map((c) => c.id),
        keys,
        expectedSchema: '0'.repeat(64),
        sourceChanged: false,
      }),
    ).toEqual([]);
    expect(keyWarnings(keys, usage, plan).affectedSubmissions).toBe(0);
  });
});
