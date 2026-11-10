import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Ops from './Ops.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ http: { request } }));
vi.mock('$lib/admin/guard.svelte', () => ({ handleSessionError: () => false }));
const form = '11111111-1111-4111-8111-111111111111';
beforeEach(() => {
  request.mockReset();
  request.mockImplementation(async (_method: string, path: string) => ({
    ok: true,
    data: path.startsWith('/ops/access')
      ? { system: false, cleanup: false, forms: [{ id: form, name: 'Kontakt' }] }
      : {
          items: [
            {
              id: 1,
              event: 'accepted',
              operation: 'mail',
              priority: 1,
              occurredAt: '2026-11-03T10:00:00Z',
            },
          ],
          next: null,
        },
  }));
});
it('zeigt Zeitpunkte deutsch statt als ISO und blendet leere Spalten aus', async () => {
  render(Ops);
  expect((await screen.findAllByText('03.11.2026, 10:00')).length).toBeGreaterThan(0);
  expect(screen.queryByText('2026-11-03T10:00:00Z')).toBeNull();
  expect(screen.queryByRole('columnheader', { name: /Einsendung/ })).toBeNull();
});
it('übersetzt das Datumsfeld in eine UTC-Grenze der Abfrage', async () => {
  render(Ops);
  await screen.findAllByText('03.11.2026, 10:00');
  await fireEvent.input(screen.getByLabelText('Von (UTC)'), { target: { value: '03.11.2026' } });
  await fireEvent.submit(screen.getByText('Anwenden').closest('form')!);
  await waitFor(() =>
    expect(request).toHaveBeenLastCalledWith(
      'GET',
      expect.stringContaining('from=2026-11-03T00%3A00%3A00Z'),
    ),
  );
});
