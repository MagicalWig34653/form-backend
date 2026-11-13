import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Connections from './Connections.svelte';

const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', async () => {
  const actual = await vi.importActual<typeof import('$lib/api/admin')>('$lib/api/admin');
  return { http: { request }, adminApi: actual.createAdminApi({ request } as never) };
});
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));

const smtp = (id: string, name: string, config: Record<string, unknown>) => ({
  id,
  kind: 'smtp',
  name,
  enabled: true,
  hasCredential: false,
  config: { host: 'mail.example.org', port: 587, security: 'starttls', ...config },
});

beforeEach(() => {
  history.replaceState(null, '', '/connections');
  request.mockReset();
});

it('kennzeichnet Verbindungen ohne Zertifikatsprüfung in der Liste', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [
        smtp('a', 'Geprüft', {}),
        smtp('b', 'Eigenes Zertifikat', { verifyCertificate: false }),
      ],
    },
  });
  render(Connections);
  await screen.findByText('Zertifikat wird nicht geprüft');
  expect(screen.getAllByText('Zertifikat wird nicht geprüft')).toHaveLength(1);
});

it('legt eine Verbindung standardmäßig mit Prüfung an und zeigt den Warnhinweis beim Schalter', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [] } });
  render(Connections);
  await fireEvent.click((await screen.findAllByRole('button', { name: 'Verbindung anlegen' }))[0]!);
  await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Relay' } });
  await fireEvent.input(screen.getByLabelText('Server'), { target: { value: 'mail.example.org' } });
  const box = screen.getByLabelText(
    'Eigene/selbstsignierte Zertifikate erlauben',
  ) as HTMLInputElement;
  expect(box.checked).toBe(false);
  expect(screen.queryByText(/Mails können abgefangen werden/)).toBeNull();
  await fireEvent.click(box);
  expect(screen.getByText(/Mails können abgefangen werden/)).toBeTruthy();
  expect(screen.getByText(/Das Zertifikat des Mailservers wird nicht geprüft/)).toBeTruthy();
  await fireEvent.click(box);

  request.mockResolvedValueOnce({ ok: true, data: { id: 'x' } });
  await fireEvent.submit(screen.getByLabelText('Name').closest('form')!);
  await waitFor(() => expect(request.mock.calls.some(([m]) => m === 'POST')).toBe(true));
  const posted = request.mock.calls.find(([m]) => m === 'POST')!;
  expect(posted[2].body.config.verifyCertificate).toBeUndefined();
});

it('sendet verifyCertificate:false nur bei ausdrücklich gesetztem Schalter', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [] } });
  render(Connections);
  await fireEvent.click((await screen.findAllByRole('button', { name: 'Verbindung anlegen' }))[0]!);
  await fireEvent.input(screen.getByLabelText('Name'), { target: { value: 'Relay' } });
  await fireEvent.input(screen.getByLabelText('Server'), { target: { value: 'mail.example.org' } });
  await fireEvent.click(screen.getByLabelText('Eigene/selbstsignierte Zertifikate erlauben'));
  request.mockResolvedValueOnce({ ok: true, data: { id: 'x' } });
  await fireEvent.submit(screen.getByLabelText('Name').closest('form')!);
  await waitFor(() => expect(request.mock.calls.some(([m]) => m === 'POST')).toBe(true));
  const posted = request.mock.calls.find(([m]) => m === 'POST')!;
  expect(posted[2].body.config.verifyCertificate).toBe(false);
});

it('der Schalter fehlt bei unverschlüsselter Verbindung und beim Mail-Proxy', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [] } });
  render(Connections);
  await fireEvent.click((await screen.findAllByRole('button', { name: 'Verbindung anlegen' }))[0]!);
  await fireEvent.change(screen.getByLabelText('Verschlüsselung'), { target: { value: 'plain' } });
  expect(screen.queryByLabelText('Eigene/selbstsignierte Zertifikate erlauben')).toBeNull();
  await fireEvent.change(screen.getByLabelText('Verschlüsselung'), { target: { value: 'tls' } });
  expect(screen.getByLabelText('Eigene/selbstsignierte Zertifikate erlauben')).toBeTruthy();
  await fireEvent.change(screen.getByLabelText('Art'), { target: { value: 'mail-proxy' } });
  expect(screen.queryByLabelText('Eigene/selbstsignierte Zertifikate erlauben')).toBeNull();
});

// Operator path, finding C (13.11.2026): a connection taken over by the Umstieg is disabled; the row menu activates it on the server.
it('aktiviert eine deaktivierte (übernommene) Verbindung über das Zeilenmenü', async () => {
  request.mockImplementation(async (method: string, path: string) => {
    if (method === 'GET' && path === '/connections')
      return { ok: true, data: { items: [{ ...smtp('imp', 'Alt-SMTP', {}), enabled: false }] } };
    if (method === 'PUT') return { ok: true, data: undefined };
    return { ok: true, data: { items: [] } };
  });
  render(Connections);
  await fireEvent.click(await screen.findByRole('button', { name: /Aktionen für Alt-SMTP/ }));
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Verbindung aktivieren' }));
  await waitFor(() =>
    expect(request).toHaveBeenCalledWith('PUT', '/connections/imp/enabled', {
      body: { enabled: true },
    }),
  );
  expect(await screen.findByText(/Die Verbindung ist aktiv/)).toBeTruthy();
});
