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
    data:
      path === '/ops/access'
        ? { system: false, cleanup: false, forms: [{ id: form, name: 'Kontakt' }] }
        : { items: [], next: null },
  }));
});
it('begrenzt auf erlaubte Formulare und zeigt eine echte Leeranzeige', async () => {
  render(Ops);
  await screen.findByText('Keine passenden Ereignisse.');
  expect(request).toHaveBeenCalledWith('GET', `/ops?form=${form}&limit=50&alarms=1`);
  expect(screen.queryByText('Abgelaufene Einträge bereinigen')).toBeNull();
});
it('sendet Filter und erhält beim Paging denselben Abfragevertrag', async () => {
  render(Ops);
  await screen.findByText('Keine passenden Ereignisse.');
  await fireEvent.change(screen.getByLabelText('Ereignis'), { target: { value: 'failed' } });
  request.mockResolvedValueOnce({
    ok: true,
    data: {
      items: [
        {
          id: 8,
          event: 'failed',
          operation: 'mail',
          priority: 1,
          occurredAt: '2026-11-03T10:00:00Z',
        },
      ],
      next: 8,
    },
  });
  await fireEvent.submit(screen.getByText('Anwenden').closest('form')!);
  await fireEvent.click(await screen.findByText('Weitere laden'));
  await waitFor(() =>
    expect(request).toHaveBeenLastCalledWith(
      'GET',
      `/ops?form=${form}&limit=50&event=failed&alarms=1&before=8`,
    ),
  );
});
it('zeigt einen Ladefehler statt einer falschen Leeranzeige', async () => {
  request.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 403 } });
  render(Ops);
  expect((await screen.findByRole('alert')).textContent).toContain('Berechtigung');
  expect(screen.queryByText('Keine passenden Ereignisse.')).toBeNull();
});
