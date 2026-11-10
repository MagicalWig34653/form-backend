import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Settings from './Settings.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ http: { request } }));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
const snapshot = {
  revision: 'r1',
  items: [
    {
      definition: {
        key: 'mail.allowedNets',
        group: 'Mail-Netze',
        envName: 'FORM_MAIL_ALLOWED_NETS',
        type: 'cidrs',
        restartRequired: true,
      },
      value: '',
      source: 'env',
      locked: true,
    },
    {
      definition: {
        key: 'mcp.requestsPerMinute',
        group: 'MCP-Token-Ratelimit',
        envName: 'FORM_MCP_TOKEN_RATE_LIMIT',
        type: 'integer',
        restartRequired: false,
      },
      value: '60',
      source: 'default',
      locked: false,
    },
  ],
};
beforeEach(() => {
  request.mockReset();
  request.mockResolvedValue({ ok: true, data: snapshot });
});
it('zeigt ENV-Sperre und Neustart; sendet nur Änderungen mit Revision', async () => {
  render(Settings);
  expect(
    ((await screen.findByLabelText('Erlaubte Netze für Mailserver')) as HTMLInputElement).disabled,
  ).toBe(true);
  const row = screen.getByLabelText('Erlaubte Netze für Mailserver').closest('[data-setting]')!;
  expect(row.textContent).toContain('Quelle:');
  expect(row.textContent).toContain('ENV');
  expect(row.textContent).toContain('Durch ENV gesperrt');
  expect(row.textContent).toContain('Neustart nötig');
  expect(
    screen.getByLabelText('Erlaubte Netze für Mailserver').getAttribute('aria-describedby'),
  ).toBe('mail.allowedNets-hint');
  await fireEvent.input(screen.getByLabelText('Anfragen je MCP-Token'), {
    target: { value: '90' },
  });
  await fireEvent.click(screen.getByRole('button', { name: 'Speichern' }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('PUT', '/settings', {
      body: { revision: 'r1', values: { 'mcp.requestsPerMinute': '90' } },
    }),
  );
});
it('überschreibt einen Konflikt nicht', async () => {
  render(Settings);
  await fireEvent.input(await screen.findByLabelText('Anfragen je MCP-Token'), {
    target: { value: '90' },
  });
  request.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 409 } });
  await fireEvent.click(screen.getByRole('button', { name: 'Speichern' }));
  expect((await screen.findByRole('alert')).textContent).toContain('zwischenzeitlich');
  expect((screen.getByLabelText('Anfragen je MCP-Token') as HTMLInputElement).value).toBe('90');
});
it('zeigt den Speicherstatus je Karte und kann Werte auf Standard setzen', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      revision: 'r1',
      items: [
        {
          definition: { ...snapshot.items[1]!.definition, defaultValue: '60' },
          value: '90',
          source: 'db',
          locked: false,
        },
      ],
    },
  });
  render(Settings);
  const input = (await screen.findByLabelText('Anfragen je MCP-Token')) as HTMLInputElement;
  expect(screen.getByText('Keine Änderungen')).toBeTruthy();
  expect(screen.getByText('pro Minute')).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: /auf Standard zurücksetzen/ }));
  expect(input.value).toBe('60');
  expect(screen.getByText('Nicht gespeichert')).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: 'Verwerfen' }));
  expect(input.value).toBe('90');
});
it('schreibt gesetzte ENV-Werte nicht und nennt fehlende ENV-Namen', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      revision: 'r1',
      items: [
        {
          definition: { ...snapshot.items[1]!.definition, envName: '' },
          value: '60',
          source: 'default',
          locked: false,
        },
      ],
    },
  });
  render(Settings);
  await screen.findByLabelText('Anfragen je MCP-Token');
  expect(screen.getByText(/keine ENV-Variable/)).toBeTruthy();
});
