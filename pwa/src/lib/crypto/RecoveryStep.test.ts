import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, expect, it, vi } from 'vitest';
vi.mock('$lib/api', () => ({
  adminApi: {
    keyBundle: async () => ({ ok: true, data: { recovery: null, accountPublicKey: null } }),
  },
}));
vi.mock('./automation.svelte', () => ({ accessAutomation: { run: vi.fn() } }));
import RecoveryStep from './RecoveryStep.svelte';
import { keyring } from './keyring.svelte';
afterEach(() => {
  keyring.lock();
  vi.restoreAllMocks();
});
it('zeigt die Einmalanzeige mit Speicheraktionen und bestätigt erst nach korrekter Wiederholung', async () => {
  const done = vi.fn();
  vi.spyOn(keyring, 'prepareRecovery').mockImplementation(async () => {
    keyring.recoveryCode = 'ABCD-TEST';
    return null;
  });
  const confirm = vi
    .spyOn(keyring, 'confirmRecovery')
    .mockImplementation(async (value) => (value === 'ABCD-TEST' ? null : 'mismatch'));
  render(RecoveryStep, { oncomplete: done });
  await fireEvent.click(
    await screen.findByRole('button', { name: 'Wiederherstellungscode vorbereiten' }),
  );
  expect(screen.getByTestId('account-recovery-code').textContent).toBe('ABCD-TEST');
  expect(screen.getByRole('button', { name: 'Als Datei speichern' })).toBeTruthy();
  expect(screen.getByRole('button', { name: 'Kopieren' })).toBeTruthy();
  const input = screen.getByLabelText('Code zur Bestätigung erneut eingeben');
  await fireEvent.input(input, { target: { value: 'falsch' } });
  await fireEvent.submit(input.closest('form')!);
  expect(done).not.toHaveBeenCalled();
  await fireEvent.input(input, { target: { value: 'ABCD-TEST' } });
  await fireEvent.submit(input.closest('form')!);
  await waitFor(() => expect(done).toHaveBeenCalledOnce());
  expect(confirm).toHaveBeenLastCalledWith('ABCD-TEST');
});
