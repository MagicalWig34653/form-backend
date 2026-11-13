import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import WebhooksPanel from './WebhooksPanel.svelte';

const mock = vi.hoisted(() => ({ request: vi.fn() }));
vi.mock('$lib/api', () => ({ http: { request: mock.request } }));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));

const hook = {
  id: 'h1',
  targetURL: 'https://example.org/hook',
  publicKey: 'pk',
  createdAt: '2026-11-04T00:00:00Z',
  active: true,
};

beforeEach(() => {
  vi.resetAllMocks();
});

describe('WebhooksPanel', () => {
  it('lists endpoints and toggles one', async () => {
    mock.request.mockImplementation(async (method: string) =>
      method === 'GET' ? { ok: true, data: { items: [hook] } } : { ok: true, data: undefined },
    );
    render(WebhooksPanel, { tenant: 't', form: 'f' });
    expect(await screen.findByText('https://example.org/hook')).toBeTruthy();
    await fireEvent.click(screen.getByRole('button', { name: 'Pausieren' }));
    await waitFor(() =>
      expect(mock.request).toHaveBeenCalledWith('PUT', '/tenants/t/forms/f/webhooks/h1', {
        body: { active: false },
      }),
    );
  });

  it('shows the private signing key once after creating', async () => {
    mock.request.mockImplementation(async (method: string) =>
      method === 'POST'
        ? { ok: true, data: { ...hook, privateKey: 'SECRET-KEY' } }
        : { ok: true, data: { items: [] } },
    );
    render(WebhooksPanel, { tenant: 't', form: 'f' });
    await screen.findByText('Noch kein Webhook eingerichtet.');
    await fireEvent.input(screen.getByLabelText('Zieladresse (https)'), {
      target: { value: 'https://example.org/hook' },
    });
    await fireEvent.click(screen.getByRole('button', { name: 'Webhook anlegen' }));
    expect(await screen.findByText('SECRET-KEY')).toBeTruthy();
    await fireEvent.click(screen.getByRole('button', { name: 'Schlüssel gesichert' }));
    expect(screen.queryByText('SECRET-KEY')).toBeNull();
  });
});
