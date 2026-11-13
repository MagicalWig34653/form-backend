import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Audit from './Audit.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ http: { request } }));
vi.mock('$lib/admin/guard.svelte', () => ({ handleSessionError: () => false }));
const entry = {
  id: '22222222-2222-4222-8222-222222222222',
  occurredAt: '2026-11-03T10:00:00.000Z',
  category: 'key',
  action: 'key.rotate',
  actorId: '33333333-3333-4333-8333-333333333333',
  actorKind: 'human',
  customerId: '44444444-4444-4444-8444-444444444444',
  formId: null,
  subjectId: null,
};
beforeEach(() => {
  request.mockReset();
  request.mockResolvedValue({ ok: true, data: { items: [], nextCursor: null } });
});
it('zeigt eine echte Leeranzeige', async () => {
  render(Audit);
  await screen.findByText('Keine passenden Einträge.');
  expect(request).toHaveBeenCalledWith('GET', '/audit?limit=50');
});
it('zeigt Einträge ohne Inhalte und pagt mit dem Cursor', async () => {
  request.mockResolvedValueOnce({ ok: true, data: { items: [entry], nextCursor: 'abc_-' } });
  render(Audit);
  await screen.findAllByText('key.rotate');
  expect(screen.getAllByText(/Mensch/).length).toBeGreaterThan(0);
  request.mockResolvedValueOnce({ ok: true, data: { items: [], nextCursor: null } });
  await fireEvent.click(screen.getByText('Weitere laden'));
  await waitFor(() =>
    expect(request).toHaveBeenLastCalledWith('GET', '/audit?limit=50&cursor=abc_-'),
  );
  expect(screen.queryByText('Weitere laden')).toBeNull();
});
it('sendet Filter für Aktion, Akteur und Zeitraum', async () => {
  render(Audit);
  await screen.findByText('Keine passenden Einträge.');
  await fireEvent.input(screen.getByLabelText('Aktion'), { target: { value: 'key.rotate' } });
  await fireEvent.input(screen.getByLabelText('Akteur (Konto-ID)'), {
    target: { value: entry.actorId },
  });
  await fireEvent.submit(screen.getByText('Anwenden').closest('form')!);
  await waitFor(() =>
    expect(request).toHaveBeenLastCalledWith(
      'GET',
      `/audit?limit=50&action=key.rotate&actor=${entry.actorId}`,
    ),
  );
});
it('sperrt ungültige Eingaben, ohne anzufragen', async () => {
  render(Audit);
  await screen.findByText('Keine passenden Einträge.');
  request.mockClear();
  await fireEvent.input(screen.getByLabelText('Akteur (Konto-ID)'), { target: { value: 'x' } });
  expect(await screen.findByText(/gültige Konto-ID/)).toBeTruthy();
  await fireEvent.submit(screen.getByText('Anwenden').closest('form')!);
  expect(request).not.toHaveBeenCalled();
});
it('zeigt bei fehlendem Recht einen Fehler statt einer Leeranzeige', async () => {
  request.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 403 } });
  render(Audit);
  expect((await screen.findByRole('alert')).textContent).toContain('Berechtigung');
  expect(screen.queryByText('Keine passenden Einträge.')).toBeNull();
});
it('zeigt andere Ladefehler statt einer Leeranzeige', async () => {
  request.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 500 } });
  render(Audit);
  await screen.findByRole('alert');
  expect(screen.queryByText('Keine passenden Einträge.')).toBeNull();
});
