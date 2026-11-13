import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Accounts from './Accounts.svelte';
import Members from './Members.svelte';
import { matchRoute } from '$lib/routes';

const api = vi.hoisted(() => ({
  request: vi.fn(),
  members: vi.fn(),
  setMemberPermissions: vi.fn(),
  session: vi.fn(),
}));
vi.mock('$lib/api', () => ({
  http: { request: api.request },
  adminApi: { members: api.members, setMemberPermissions: api.setMemberPermissions },
  authApi: { session: api.session },
}));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
vi.mock('$lib/session.svelte', () => ({
  session: {
    me: { id: 'me', username: 'admin', systemAdministrator: true },
    tenants: [{ id: 'aaaaaaaa-1111-4111-8111-11111111111a', name: 'Kunde A', permissions: [] }],
  },
}));
const tenant = 'aaaaaaaa-1111-4111-8111-11111111111a';

beforeEach(() => {
  vi.resetAllMocks();
  api.session.mockResolvedValue({ ok: true, data: { secondFactorRequired: true } });
  api.request.mockResolvedValue({
    ok: true,
    data: {
      items: [
        { id: 'me', username: 'admin', active: true, mcpAllowed: true },
        { id: 'u2', username: 'erika', active: true, mcpAllowed: false },
      ],
    },
  });
  api.members.mockResolvedValue({
    ok: true,
    data: {
      items: [{ accountId: 'me', username: 'admin', permissions: ['form.read'], inherited: [] }],
      assignable: ['form.read'],
    },
  });
  api.setMemberPermissions.mockResolvedValue({ ok: true, data: undefined });
});

it('kennt die systemweite Kontenseite', () => {
  expect(matchRoute('/accounts')).toEqual({ name: 'accounts' });
});
it('listet alle Konten im Systembereich und öffnet das Anlegen im Seitenkopf', async () => {
  render(Accounts);
  expect(await screen.findByText('erika')).toBeTruthy();
  expect(screen.queryByLabelText('Benutzername')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Konto anlegen' }));
  expect(await screen.findByLabelText('Benutzername')).toBeTruthy();
});
it('zeigt im Kunden-Reiter keine systemweiten Konten mehr, aber Mitglied hinzufügen', async () => {
  render(Members, { tenant });
  await screen.findByText('Mitglieder und Rechte');
  expect(
    screen.queryByText('Alle Konten im System: sperren, entsperren und MCP-Zugang steuern.'),
  ).toBeNull();
  await fireEvent.change(await screen.findByLabelText('Konto wählen'), { target: { value: 'u2' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Mitglied hinzufügen' }));
  await waitFor(() =>
    expect(api.setMemberPermissions).toHaveBeenCalledWith(tenant, 'u2', ['form.read']),
  );
});

it('zeigt Konten als Tabelle mit Sie-Marke, Kunden und gesperrter Selbstsperre im Menü', async () => {
  render(Accounts);
  expect(await screen.findByRole('columnheader', { name: 'Status' })).toBeTruthy();
  expect(screen.getByRole('columnheader', { name: 'MCP' })).toBeTruthy();
  await waitFor(() => expect(screen.getByRole('columnheader', { name: 'Kunden' })).toBeTruthy());
  expect(screen.getAllByText('MCP erlaubt').length).toBeGreaterThan(0);
  expect(screen.getAllByText('MCP gesperrt').length).toBeGreaterThan(0);
  expect(screen.getAllByText('Sie')).toHaveLength(1);
  // The own account is a system administrator and so reaches every customer.
  expect(screen.getAllByText('Alle Kunden (Systemrecht)').length).toBeGreaterThan(0);
  await fireEvent.keyDown(screen.getByRole('button', { name: 'Aktionen für Konto admin' }), {
    key: 'Enter',
  });
  const lock = await screen.findByRole('menuitem', { name: 'Konto sperren' });
  expect(lock.getAttribute('aria-disabled') ?? lock.getAttribute('data-disabled')).not.toBeNull();
});
