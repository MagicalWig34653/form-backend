import { describe, expect, it, vi } from 'vitest';
import {
  deriveSteps,
  emptyFacts,
  nextOpenStep,
  progressOf,
  stepScope,
  type Facts,
  type StepId,
} from './onboarding';
import { loadFacts } from './onboarding.svelte';

vi.mock('$lib/api', () => ({ http: { request: vi.fn() }, adminApi: {} }));
vi.mock('$lib/session.svelte', () => ({ session: { me: null, status: 'ready' } }));

const done: Facts = {
  account: true,
  recovery: true,
  mail: 1,
  addresses: true,
  customers: 1,
  forms: { total: 1, published: 1 },
  migration: { available: true, jobs: 1 },
};
const stateOf = (facts: Facts, skipped: StepId[] = []) =>
  Object.fromEntries(deriveSteps(facts, skipped).map((s) => [s.id, s.state]));

describe('Schrittableitung', () => {
  it('zeigt nur Schritte, die es gibt, und blendet den Umstieg ohne Recht aus', () => {
    const steps = deriveSteps({ ...done, migration: { available: false, jobs: null } });
    expect(steps.map((s) => s.id)).toEqual([
      'account',
      'recovery',
      'mail',
      'addresses',
      'customer',
      'form',
    ]);
    expect(deriveSteps(done)).toHaveLength(7);
  });

  it('leitet erledigt aus den Daten ab', () => {
    expect(Object.values(stateOf(done)).every((s) => s === 'done')).toBe(true);
    expect(
      stateOf({
        ...done,
        recovery: false,
        mail: 0,
        customers: 0,
        forms: { total: 0, published: 0 },
        migration: { available: true, jobs: 0 },
      }),
    ).toMatchObject({
      account: 'done',
      recovery: 'open',
      mail: 'open',
      customer: 'open',
      form: 'open',
      migration: 'open',
    });
  });

  it('unveröffentlichtes Formular ist offen und nennt den Grund', () => {
    const steps = deriveSteps({
      ...done,
      forms: { total: 2, published: 0, unpublished: { tenant: 't', form: 'f' } },
    });
    expect(steps.find((s) => s.id === 'form')).toMatchObject({
      state: 'open',
      detail: 'draftOnly',
    });
    const none = deriveSteps({ ...done, customers: 0, forms: { total: 0, published: 0 } });
    expect(none.find((s) => s.id === 'form')?.detail).toBe('needsCustomer');
  });

  it('erfindet keinen Status: unbekannte Daten sind ein Fehler', () => {
    const s = stateOf(emptyFacts);
    expect(s).toMatchObject({
      account: 'error',
      recovery: 'error',
      mail: 'error',
      customer: 'error',
      form: 'error',
    });
    expect(Object.values(s)).not.toContain('done');
    expect(Object.values(s)).not.toContain('open');
  });

  it('verschiebt nur optionale Schritte; Erledigtes bleibt erledigt', () => {
    const open: Facts = { ...done, recovery: false, mail: 0, addresses: false };
    expect(stateOf(open, ['mail', 'addresses', 'recovery'])).toMatchObject({
      mail: 'skipped',
      addresses: 'skipped',
      recovery: 'open',
    });
    expect(stateOf(done, ['mail']).mail).toBe('done');
    expect(stateOf({ ...done, mail: null }, ['mail']).mail).toBe('skipped');
  });

  it('Fortschritt, aktueller und nächster Schritt', () => {
    const steps = deriveSteps(
      { ...done, mail: 0, customers: 0, forms: { total: 0, published: 0 } },
      ['mail'],
    );
    const p = progressOf(steps);
    expect(p).toMatchObject({ done: 4, handled: 5, total: 7, complete: false });
    expect(steps[p.current]?.id).toBe('customer');
    expect(nextOpenStep(steps, 'customer')?.id).toBe('form');
    expect(nextOpenStep(steps, 'form')?.id).toBe('customer');
    const all = deriveSteps(done);
    expect(progressOf(all)).toMatchObject({ complete: true, current: -1 });
    expect(nextOpenStep(all, 'account')).toBeNull();
  });

  it('Kontext gilt nur auf den Seiten des Schritts', () => {
    expect(stepScope('mail', { name: 'connections' })).toBe(true);
    expect(stepScope('mail', { name: 'settings' })).toBe(false);
    expect(stepScope('form', { name: 'form', tenant: 't', form: 'f', tab: 'publish' })).toBe(true);
    expect(stepScope('migration', { name: 'overview' })).toBe(false);
  });
});

describe('Fakten laden', () => {
  const ok = <T>(data: T) => ({ ok: true as const, data });
  const fail = { ok: false as const, error: { kind: 'network' as const, message: 'x' } };
  function deps(over: Record<string, unknown> = {}) {
    const request = vi.fn(async (_m: string, path: string) => {
      if (path === '/settings')
        return ok({
          revision: 'r9',
          items: [
            { definition: { key: 'admin.origin' }, value: 'https://a.example', source: 'db' },
            { definition: { key: 'admin.rpID' }, value: '', source: 'env' },
          ],
        });
      if (path === '/migration/jobs') return ok({ items: [{}, {}] });
      return fail;
    });
    const adminApi = {
      keyBundle: async () => ok({ recovery: { x: 1 } }),
      connections: async () => ok({ items: [{ enabled: true }, { enabled: false }] }),
      tenants: async () => ok({ items: [{ id: 'a' }, { id: 'b' }] }),
      forms: async (tenant: string) =>
        ok({
          items:
            tenant === 'a'
              ? [{ id: 'f1', currentReleaseId: null }]
              : [{ id: 'f2', currentReleaseId: 'r' }],
          nextCursor: null,
        }),
      ...over,
    };
    return { http: { request }, adminApi } as never;
  }
  const all: StepId[] = [
    'account',
    'recovery',
    'mail',
    'addresses',
    'customer',
    'form',
    'migration',
  ];

  it('liest echte Werte', async () => {
    const r = await loadFacts(
      deps(),
      all,
      { required: true, migrationAllowed: true, migrationEnabled: true },
      true,
    );
    expect(r.revision).toBe('r9');
    expect(r.facts).toMatchObject({
      account: true,
      recovery: true,
      mail: 1,
      addresses: true,
      customers: 2,
      forms: { total: 2, published: 1, unpublished: { tenant: 'a', form: 'f1' } },
      migration: { available: true, jobs: 2 },
    });
  });

  it('Fehler bleiben unbekannt statt offen', async () => {
    const bad = deps({
      keyBundle: async () => fail,
      connections: async () => fail,
      tenants: async () => fail,
    });
    const r = await loadFacts(bad, all, { required: true, migrationAllowed: false }, false);
    expect(r.facts).toMatchObject({
      account: false,
      recovery: null,
      mail: null,
      customers: null,
      forms: null,
      migration: { available: false, jobs: null },
    });
  });

  it('Formularliste mit Fehler ohne Beleg ist unbekannt', async () => {
    const partial = deps({
      forms: async (tenant: string) =>
        tenant === 'a'
          ? fail
          : ok({ items: [{ id: 'f2', currentReleaseId: null }], nextCursor: null }),
    });
    const r = await loadFacts(partial, ['form'], { required: true }, true);
    expect(r.facts.forms).toBeNull();
  });
});
