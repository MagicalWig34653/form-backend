import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { expect, it, vi, beforeEach } from 'vitest';
import ActiveSwitch from './ActiveSwitch.svelte';
const setFormActive = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({ adminApi: { setFormActive } }));
vi.mock('$lib/admin/guard.svelte', () => ({ handleSessionError: () => false }));
beforeEach(() => {
  vi.clearAllMocks();
  vi.stubGlobal(
    'confirm',
    vi.fn(() => true),
  );
});
it('aktiviert ein pausiertes Formular und meldet die Änderung', async () => {
  setFormActive.mockResolvedValue({ ok: true, data: undefined });
  const onchange = vi.fn();
  render(ActiveSwitch, { tenant: 't', form: 'f', active: false, onchange });
  expect(screen.getByText(/Einsendungen werden abgewiesen/)).toBeTruthy();
  await fireEvent.click(screen.getByRole('button', { name: 'Aktivieren' }));
  await waitFor(() => expect(onchange).toHaveBeenCalledOnce());
  expect(setFormActive).toHaveBeenCalledWith('t', 'f', true);
});
it('pausiert nur nach Bestätigung und zeigt Fehler', async () => {
  setFormActive.mockResolvedValue({ ok: false, error: { status: 403 } });
  const onchange = vi.fn();
  render(ActiveSwitch, { tenant: 't', form: 'f', active: true, onchange });
  vi.stubGlobal(
    'confirm',
    vi.fn(() => false),
  );
  await fireEvent.click(screen.getByRole('button', { name: 'Pausieren' }));
  expect(setFormActive).not.toHaveBeenCalled();
  vi.stubGlobal(
    'confirm',
    vi.fn(() => true),
  );
  await fireEvent.click(screen.getByRole('button', { name: 'Pausieren' }));
  await screen.findByText('Der Status konnte nicht geändert werden.');
  expect(setFormActive).toHaveBeenCalledWith('t', 'f', false);
  expect(onchange).not.toHaveBeenCalled();
});
