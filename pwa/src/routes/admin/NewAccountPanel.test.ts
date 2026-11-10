import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import { t } from '$lib/i18n';
import NewAccountPanel from './NewAccountPanel.svelte';

const api = vi.hoisted(() => ({ session: vi.fn(), createAccount: vi.fn() }));
vi.mock('$lib/api', () => ({
  authApi: { session: api.session },
  adminApi: { createAccount: api.createAccount },
}));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
const a = t.admin.account;

beforeEach(() => {
  vi.resetAllMocks();
  api.session.mockResolvedValue({ ok: true, data: { secondFactorRequired: true } });
});

it('verlangt ein Passwort nur, wenn die Installation einen zweiten Faktor fordert', async () => {
  render(NewAccountPanel);
  expect(await screen.findByLabelText(a.password)).toBeTruthy();
});
it('blendet das Passwortfeld aus, wenn kein zweiter Faktor nötig ist', async () => {
  api.session.mockResolvedValue({ ok: true, data: { secondFactorRequired: false } });
  render(NewAccountPanel);
  await waitFor(() => expect(api.session).toHaveBeenCalled());
  await Promise.resolve();
  expect(screen.queryByLabelText(a.password)).toBeNull();
});
it('legt ein Konto an, zeigt den einmaligen Link und leert Benutzername und Passwort', async () => {
  api.createAccount.mockResolvedValue({
    ok: true,
    data: { setupLink: 'https://x.example/setup#abc' },
  });
  const oncreated = vi.fn();
  render(NewAccountPanel, { oncreated });
  const name = (await screen.findByLabelText(a.username)) as HTMLInputElement;
  const password = (await screen.findByLabelText(a.password)) as HTMLInputElement;
  await fireEvent.input(name, { target: { value: ' anna ' } });
  await fireEvent.input(password, { target: { value: 'ein-langes-passwort' } });
  await fireEvent.click(screen.getByRole('button', { name: a.createBtn }));
  expect((await screen.findByTestId('setup-link')).textContent).toBe('https://x.example/setup#abc');
  expect(api.createAccount).toHaveBeenCalledWith('anna', 'ein-langes-passwort');
  expect(oncreated).toHaveBeenCalledTimes(1);
  expect(name.value).toBe('');
  expect(password.value).toBe('');
});
it('meldet vergebene Namen und andere Fehler getrennt und zeigt dann keinen Link', async () => {
  api.createAccount.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 409 } });
  render(NewAccountPanel);
  await fireEvent.input(await screen.findByLabelText(a.username), { target: { value: 'anna' } });
  await fireEvent.input(screen.getByLabelText(a.password), {
    target: { value: 'ein-langes-passwort' },
  });
  await fireEvent.click(screen.getByRole('button', { name: a.createBtn }));
  expect(await screen.findByText(a.exists)).toBeTruthy();
  api.createAccount.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 500 } });
  await fireEvent.input(screen.getByLabelText(a.password), {
    target: { value: 'ein-langes-passwort' },
  });
  await fireEvent.click(screen.getByRole('button', { name: a.createBtn }));
  expect(await screen.findByText(a.failed)).toBeTruthy();
  expect(screen.queryByTestId('setup-link')).toBeNull();
});
