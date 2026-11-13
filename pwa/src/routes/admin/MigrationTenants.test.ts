import { render, screen } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Migration from './Migration.svelte';
const request = vi.hoisted(() => vi.fn());
const refreshTenants = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({
  http: { request },
  adminApi: { tenants: async () => ({ ok: true, data: { items: [] } }) },
}));
vi.mock('$lib/admin/guard.svelte', () => ({ reauthenticate: vi.fn() }));
vi.mock('$lib/session.svelte', () => ({ session: { refreshTenants } }));
beforeEach(() => {
  request.mockReset();
  refreshTenants.mockReset();
});

// QA finding 7B5E1E8A: the session list of customers is loaded at login. A customer created by the import must reach it, otherwise
// Account, Advanced shows no field to adopt the old key.
it('lädt die Kundenliste der Sitzung neu, sobald ein Import zur Prüfung ansteht (einmal je Lauf)', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [{ id: 'j1', state: 'review', phase: 'done', dryRun: false, error: '', report: {} }],
    },
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  expect(refreshTenants).toHaveBeenCalledTimes(1);
});

it('lädt die Kundenliste nicht neu beim bloßen Prüflauf', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [{ id: 'j2', state: 'review', phase: 'done', dryRun: true, error: '', report: {} }],
    },
  });
  render(Migration);
  await vi.waitFor(() => expect(request).toHaveBeenCalled());
  await new Promise((r) => setTimeout(r, 50));
  expect(refreshTenants).not.toHaveBeenCalled();
});
