import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Account from './Account.svelte';

const api = vi.hoisted(() => ({
  request: vi.fn(),
  passkeys: vi.fn(),
  keyBundle: vi.fn(),
  customerKey: vi.fn(),
  addOptions: vi.fn(),
  addVerify: vi.fn(),
  create: vi.fn(),
}));
vi.mock('$lib/api', () => ({
  http: { request: api.request },
  adminApi: {
    passkeys: api.passkeys,
    keyBundle: api.keyBundle,
    customerKey: api.customerKey,
  },
  authApi: { addPasskeyOptions: api.addOptions, addPasskeyVerify: api.addVerify },
}));
vi.mock('$lib/api/webauthn', () => ({ createCredential: api.create }));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
vi.mock('$lib/session.svelte', () => ({
  session: { me: { id: 'me', username: 'admin', systemAdministrator: false }, tenants: [] },
}));

beforeEach(() => {
  vi.resetAllMocks();
  api.request.mockResolvedValue({ ok: true, data: { enabled: false } });
  api.keyBundle.mockResolvedValue({ ok: false, error: { kind: 'http', status: 404 } });
  api.passkeys.mockResolvedValue({
    ok: true,
    data: {
      items: [
        {
          credentialId: 'a',
          label: 'Laptop',
          createdAt: '2026-10-03T10:00:00Z',
          unlocksKeys: true,
        },
      ],
    },
  });
});

it('nennt Datum und Nutzen je Passkey und ersetzt den doppelten Satz', async () => {
  render(Account);
  expect(
    await screen.findByText('· angelegt 03.10.2026 · kann Einsendungen entsperren'),
  ).toBeTruthy();
  expect(screen.getByText('Laptop').className).toContain('font-medium');
  expect(screen.queryByText('Sichern Sie Ihren Wiederherstellungscode.')).toBeNull();
});

it('fügt einen Passkey über die eigene Registrierung hinzu', async () => {
  api.addOptions.mockResolvedValue({ ok: true, data: { challengeId: 'c' } });
  api.create.mockResolvedValue({ ok: true, body: { challengeId: 'c', credential: {} } });
  api.addVerify.mockResolvedValue({ ok: true, data: { status: 'registered' } });
  render(Account);
  await fireEvent.click(await screen.findByRole('button', { name: 'Passkey hinzufügen' }));
  await waitFor(() => expect(api.addVerify).toHaveBeenCalled());
  expect(api.addVerify.mock.calls[0]![0].label).toMatch(/^Passkey vom \d\d\.\d\d\.\d{4}$/);
  expect(await screen.findByText('Der Passkey wurde hinzugefügt.')).toBeTruthy();
});

it('meldet einen abgebrochenen Dialog ohne zu registrieren', async () => {
  api.addOptions.mockResolvedValue({ ok: true, data: { challengeId: 'c' } });
  api.create.mockResolvedValue({ ok: false, reason: 'cancelled' });
  render(Account);
  await fireEvent.click(await screen.findByRole('button', { name: 'Passkey hinzufügen' }));
  expect(await screen.findByText('Das Hinzufügen wurde abgebrochen.')).toBeTruthy();
  expect(api.addVerify).not.toHaveBeenCalled();
});
