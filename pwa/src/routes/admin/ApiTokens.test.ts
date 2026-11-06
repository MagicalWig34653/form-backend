import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import ApiTokens from './ApiTokens.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ http: { request } }));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
beforeEach(() => {
  history.replaceState(null, '', '/api-tokens');
  request.mockReset();
});
it('zeigt das Geheimnis nur nach Anlage und entfernt es beim Ausblenden', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [] } });
  render(ApiTokens);
  await waitFor(() => expect(request).toHaveBeenCalledWith('GET', '/account/tokens'));
  await fireEvent.input(screen.getByLabelText('Bezeichnung'), { target: { value: 'Test' } });
  await fireEvent.input(screen.getByLabelText('Kunden-ID (UUID)'), {
    target: { value: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' },
  });
  request.mockResolvedValueOnce({ ok: true, data: { token: 'kfm_synthetic' } });
  await fireEvent.submit(screen.getByText('Token anlegen').closest('form')!);
  await screen.findByText('kfm_synthetic');
  const issued = request.mock.calls.find(([method]) => method === 'POST');
  expect(issued?.[2].body.expiresAt).toMatch(/T\d{2}:\d{2}:\d{2}Z$/);
  expect(request).toHaveBeenCalledWith(
    'POST',
    '/account/tokens',
    expect.objectContaining({ body: expect.objectContaining({ scopes: ['konfiguration.lesen'] }) }),
  );
  await fireEvent.click(screen.getByText('Ausblenden'));
  expect(screen.queryByText('kfm_synthetic')).toBeNull();
});
it('widerruft eigene Tokens und lädt die Liste neu', async () => {
  request.mockImplementation(async (_method, path) =>
    path === '/account/oauth'
      ? { ok: true, data: { items: [] } }
      : {
          ok: true,
          data: {
            items: [
              {
                id: 'id',
                label: 'Testtoken',
                expires_at: 0,
                last_used_at: null,
                revoked_at: null,
                scopes_json: '[]',
                scope_json: '{}',
              },
            ],
          },
        },
  );
  render(ApiTokens);
  await screen.findByText('Testtoken');
  await fireEvent.click(screen.getByRole('button', { name: 'Widerrufen' }));
  await waitFor(() => expect(request).toHaveBeenCalledWith('DELETE', '/account/tokens/id'));
});

it('behandelt weggelassene Nullfelder des Servers als nicht widerrufen', async () => {
  request.mockImplementation(async (_method, path) =>
    path === '/account/oauth'
      ? { ok: true, data: { items: [] } }
      : {
          ok: true,
          data: {
            items: [
              { id: 'id', label: 'OhneNull', expires_at: 0, scopes_json: '[]', scope_json: '{}' },
            ],
          },
        },
  );
  render(ApiTokens);
  await screen.findByText('OhneNull');
  expect(screen.getByRole('button', { name: 'Widerrufen' })).toBeTruthy();
});

it('zeigt Client und Scopes vor Zustimmung und sendet eine ausdrückliche Freigabe', async () => {
  history.replaceState(null, '', '/api-tokens?oauth_request=synthetic');
  request.mockImplementation(async (method, path) => {
    if (path.includes('/requests/'))
      return {
        ok: true,
        data: {
          clientName: 'Testclient',
          redirectHost: 'client.test',
          scopes: ['konfiguration.lesen'],
        },
      };
    if (method === 'POST') return { ok: false, error: { kind: 'http', status: 403 } };
    return { ok: true, data: { items: [] } };
  });
  render(ApiTokens);
  await screen.findByText('Client: Testclient');
  expect(screen.getByText('Weiterleitung an: client.test')).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Zugriff erlauben' }).hasAttribute('disabled')).toBe(
    true,
  );
  const inputs = screen.getAllByLabelText('Kunden-ID (UUID)');
  await fireEvent.input(inputs[1]!, { target: { value: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Zugriff erlauben' }));
  expect(request).toHaveBeenCalledWith(
    'POST',
    '/account/oauth/consent',
    expect.objectContaining({
      body: {
        requestId: 'synthetic',
        approve: true,
        tenantId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      },
    }),
  );
});
