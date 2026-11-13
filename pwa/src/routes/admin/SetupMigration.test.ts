import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import { onboarding } from '$lib/onboarding.svelte';
import Installation from './Installation.svelte';
import Migration from './Migration.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({
  http: { request },
  adminApi: {
    keyBundle: async () => ({ ok: true, data: { accountPublicKey: null, recovery: null } }),
    tenants: async () => ({ ok: true, data: { items: [] } }),
    connections: async () => ({ ok: false, error: { kind: 'network', message: 'x' } }),
    passkeys: async () => ({ ok: false, error: { kind: 'network', message: 'x' } }),
    entries: async () => ({ ok: false, error: { kind: 'network', message: 'x' } }),
    forms: async () => ({ ok: true, data: { items: [], nextCursor: null } }),
  },
}));
vi.mock('$lib/session.svelte', () => ({
  session: {
    me: { id: 'a', systemAdministrator: true },
    status: 'ready',
    tenants: [],
    refreshTenants: vi.fn(),
  },
}));
vi.mock('$lib/admin/guard.svelte', () => ({
  reauthenticate: vi.fn(),
  handleSessionError: vi.fn(() => false),
}));
beforeEach(() => {
  request.mockReset();
  onboarding.reset();
});
it('zeigt nur echte Schritte mit Status aus den Daten und verschiebt optionale', async () => {
  request.mockImplementation(async (_method, path) => {
    if (path === '/setup-state') return { ok: true, data: { required: true } };
    if (path === '/settings')
      return {
        ok: true,
        data: {
          revision: 'r1',
          items: [
            { definition: { key: 'admin.origin' }, value: 'https://a.example', source: 'db' },
            { definition: { key: 'admin.rpID' }, value: 'a.example', source: 'db' },
          ],
        },
      };
    return { ok: false, error: { kind: 'network', message: 'x' } };
  });
  render(Installation);
  const list = await screen.findByLabelText('Einrichtungsschritte');
  await waitFor(() => expect(list.querySelector('[data-testid="step-addresses"]')).toBeTruthy());
  // Konto und Adressen erledigt, Wiederherstellung offen, nicht ladbare Daten als Fehler.
  expect(list.querySelectorAll('li')).toHaveLength(9);
  expect(list.querySelector('[data-testid="step-account"]')?.getAttribute('data-state')).toBe(
    'done',
  );
  expect(list.querySelector('[data-testid="step-addresses"]')?.getAttribute('data-state')).toBe(
    'done',
  );
  expect(list.querySelector('[data-testid="step-mail"]')?.getAttribute('data-state')).toBe('error');
  for (const id of ['passkeys', 'token'])
    expect(list.querySelector(`[data-testid="step-${id}"]`)?.getAttribute('data-state')).toBe(
      'error',
    );
  // Ohne veröffentlichtes Formular ist die Probe-Einsendung offen, nicht erledigt.
  expect(list.querySelector('[data-testid="step-testEntry"]')?.getAttribute('data-state')).toBe(
    'open',
  );
  expect(list.querySelector('[aria-current="step"]')).toBeTruthy();
  expect(screen.getByText(/2 von 9 Schritten erledigt/)).toBeTruthy();
  // Es wird nichts mehr als Einrichtungsfortschritt gespeichert.
  expect(request.mock.calls.some(([method]) => method === 'PUT')).toBe(false);
});
it('zeigt nach Abschluss der Einrichtung die Übersicht statt einer leeren Seite', async () => {
  request.mockResolvedValue({ ok: true, data: { required: false } });
  render(Installation);
  await screen.findByText('Die Einrichtung ist abgeschlossen');
  expect(screen.getByRole('button', { name: 'Zur Übersicht' })).toBeTruthy();
  expect(request).toHaveBeenCalledTimes(1);
});
it('zeigt bestätigte Zähler und verwendet beim Fortsetzen denselben Lauf', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  request.mockImplementation(async (method) =>
    method === 'POST'
      ? { ok: true, data: {} }
      : {
          ok: true,
          data: {
            items: [
              {
                id,
                state: 'paused',
                phase: 'anfragen',
                dryRun: false,
                error: 'interrupted',
                report: { processed: 42 },
              },
            ],
          },
        },
  );
  render(Migration);
  await screen.findByText('Import: Pausiert');
  expect(screen.getByRole('status').textContent).toContain('anfragen');
  // The raw code is translated for the user.
  expect(screen.getByRole('alert').textContent).toContain('Pausiert');
  await fireEvent.click(screen.getByRole('button', { name: 'Fortsetzen' }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('POST', `/migration/jobs/${id}/resume`, {
      body: undefined,
    }),
  );
});
it('zeigt Verbindungsfehler ohne erfundene Fortschrittswerte und bietet Retry', async () => {
  request.mockResolvedValue({ ok: false, error: { kind: 'network' } });
  render(Migration);
  await screen.findByRole('alert');
  expect(screen.getByRole('alert').textContent).toContain(
    'Der bestätigte Fortschritt bleibt erhalten',
  );
  expect(screen.queryByRole('progressbar')).toBeNull();
  expect(screen.getByRole('button', { name: 'Erneut versuchen' })).toBeTruthy();
});
it('wiederholt den Prüflauf per Knopf und zeigt bei source_changed Grundtext und Knopf', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  request.mockImplementation(async (method) =>
    method === 'POST'
      ? { ok: true, data: {} }
      : {
          ok: true,
          data: {
            items: [
              {
                id,
                state: 'failed',
                phase: 'anfragen',
                dryRun: false,
                report: {},
                error: 'source_changed',
              },
            ],
          },
        },
  );
  render(Migration);
  await screen.findByRole('button', { name: 'Prüflauf wiederholen' });
  expect(screen.getByRole('alert').textContent).toContain(
    'Die Altdaten wurden seit dem Prüflauf verändert',
  );
  expect(screen.queryByRole('button', { name: 'Fortsetzen' })).toBeNull();
  expect(screen.queryByLabelText(/Snapshot-SHA256/)).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Prüflauf wiederholen' }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('POST', `/migration/jobs/${id}/rehearse`, {
      body: undefined,
    }),
  );
});
it('zeigt nach dem Prüflauf Import und Prüflauf wiederholen, aber keinen Delta-Knopf', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [
        {
          id: '11111111-1111-4111-8111-111111111111',
          state: 'review',
          phase: 'verification',
          dryRun: true,
          report: {},
        },
      ],
    },
  });
  render(Migration);
  await screen.findByRole('button', { name: 'Prüflauf wiederholen' });
  expect(screen.getByRole('button', { name: 'Import starten' })).toBeTruthy();
  expect(screen.queryByRole('button', { name: /Delta/ })).toBeNull();
});
it('lädt die Probe ohne privaten Schlüssel und verwirft ungültige lokale Eingaben', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  request.mockImplementation(async (_method, path) =>
    path.endsWith('/probe')
      ? { ok: true, data: { wire: 'invalid', hash: 'a'.repeat(64) } }
      : {
          ok: true,
          data: {
            items: [{ id, state: 'review', phase: 'verification', dryRun: false, report: {} }],
          },
        },
  );
  render(Migration);
  await fireEvent.click(await screen.findByRole('button', { name: 'Entschlüsselungsprobe laden' }));
  const input = await screen.findByLabelText('Privater Altschlüssel');
  await fireEvent.input(input, { target: { value: 'invalid-private-key' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Probe lokal entschlüsseln' }));
  await screen.findByRole('alert');
  expect((input as HTMLInputElement).value).toBe('');
  expect(request.mock.calls.every(([method]) => method === 'GET')).toBe(true);
});
