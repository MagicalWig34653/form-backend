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
  expect(((await screen.findByLabelText('mail.allowedNets')) as HTMLInputElement).disabled).toBe(
    true,
  );
  const row = screen.getByLabelText('mail.allowedNets').closest('[data-setting]')!;
  expect(row.textContent).toContain('Quelle:');
  expect(row.textContent).toContain('ENV');
  expect(row.textContent).toContain('Durch ENV gesperrt');
  expect(row.textContent).toContain('Neustart nötig');
  expect(screen.getByLabelText('mail.allowedNets').getAttribute('aria-describedby')).toBe(
    'mail.allowedNets-hint',
  );
  await fireEvent.input(screen.getByLabelText('mcp.requestsPerMinute'), {
    target: { value: '90' },
  });
  await fireEvent.submit(screen.getByText('Speichern').closest('form')!);
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('PUT', '/settings', {
      body: { revision: 'r1', values: { 'mcp.requestsPerMinute': '90' } },
    }),
  );
});
it('überschreibt einen Konflikt nicht', async () => {
  render(Settings);
  await fireEvent.input(await screen.findByLabelText('mcp.requestsPerMinute'), {
    target: { value: '90' },
  });
  request.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 409 } });
  await fireEvent.submit(screen.getByText('Speichern').closest('form')!);
  expect((await screen.findByRole('alert')).textContent).toContain('zwischenzeitlich');
  expect((screen.getByLabelText('mcp.requestsPerMinute') as HTMLInputElement).value).toBe('90');
});
