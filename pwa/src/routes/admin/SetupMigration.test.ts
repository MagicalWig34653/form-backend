import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Installation from './Installation.svelte';
import Migration from './Migration.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({
  http: { request },
  adminApi: {
    keyBundle: async () => ({ ok: true, data: { accountPublicKey: null, recovery: null } }),
    tenants: async () => ({ ok: true, data: { items: [] } }),
  },
}));
vi.mock('$lib/admin/guard.svelte', () => ({ reauthenticate: vi.fn() }));
beforeEach(() => {
  request.mockReset();
});
it('zeigt sechs Schritte und speichert den Wechsel vor Recovery über die Settingsrevision', async () => {
  request.mockImplementation(async (method, path) => {
    if (path === '/setup-state') return { ok: true, data: { required: true } };
    if (method === 'PUT') return { ok: true, data: { revision: 'r2' } };
    return {
      ok: true,
      data: { revision: 'r1', items: [{ definition: { key: 'setup.step' }, value: '0' }] },
    };
  });
  render(Installation);
  await screen.findByText('Schritt 1 von 6');
  expect(screen.getByLabelText('Einrichtungsschritte').querySelectorAll('li')).toHaveLength(6);
  await fireEvent.click(screen.getByRole('button', { name: 'Weiter' }));
  await screen.findByRole('button', { name: 'Wiederherstellungscode vorbereiten' });
  expect(request).toHaveBeenCalledWith('PUT', '/settings', {
    body: { revision: 'r1', values: { 'setup.step': '1' } },
  });
  expect(screen.queryByRole('button', { name: 'Code gesichert' })).toBeNull();
});
it('zeigt ohne Systemrecht keinen Assistenten', async () => {
  request.mockResolvedValue({ ok: true, data: { required: false } });
  render(Installation);
  await screen.findByText(
    'Die Einrichtung ist abgeschlossen oder Sie haben kein Systemrecht für die Einrichtung.',
  );
  expect(screen.queryByText('Passkey erstellen')).toBeNull();
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
  expect(screen.getByRole('alert').textContent).toContain('interrupted');
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
it('startet Delta als bewussten neuen Snapshot-Prüflauf', async () => {
  const id = '11111111-1111-4111-8111-111111111111';
  request.mockImplementation(async (method) =>
    method === 'POST'
      ? { ok: true, data: {} }
      : {
          ok: true,
          data: {
            items: [{ id, state: 'review', phase: 'verification', dryRun: false, report: {} }],
          },
        },
  );
  render(Migration);
  await screen.findByRole('button', { name: 'Delta-Prüflauf starten' });
  await fireEvent.input(screen.getByLabelText('Neuer Snapshot-SHA256 für Delta-Prüflauf'), {
    target: { value: 'a'.repeat(64) },
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Delta-Prüflauf starten' }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('POST', `/migration/jobs/${id}/delta`, {
      body: { dumpSHA256: 'a'.repeat(64) },
    }),
  );
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
