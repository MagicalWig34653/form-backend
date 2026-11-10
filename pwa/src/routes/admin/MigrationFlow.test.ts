import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Migration from './Migration.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({
  http: { request },
  adminApi: { tenants: async () => ({ ok: true, data: { items: [] } }) },
}));
vi.mock('$lib/admin/guard.svelte', () => ({ reauthenticate: vi.fn() }));
const formId = '22222222-2222-4222-8222-222222222222';
beforeEach(() => request.mockReset());
const type = (label: string, value: string) =>
  fireEvent.input(screen.getByLabelText(label, { exact: false }), { target: { value } });

it('führt je Schritt ein Panel, übernimmt Prüfwerte und startet den Prüflauf', async () => {
  request.mockImplementation(async (method, path) => {
    if (method === 'GET') return { ok: true, data: { items: [] } };
    if (path === '/migration/test')
      return {
        ok: true,
        data: { schemaHMAC: 'c'.repeat(64), formIds: [formId], counts: { submissions: 7 } },
      };
    return { ok: true, data: {} };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
  const next = () => screen.getByRole('button', { name: 'Weiter' }) as HTMLButtonElement;
  const back = () => screen.getByRole('button', { name: 'Zurück' }) as HTMLButtonElement;
  expect(next().disabled).toBe(true);
  expect(screen.queryByRole('button', { name: 'Zurück' })).toBeNull();
  expect(screen.getByText('Schritt 1 von 5')).toBeTruthy();
  // Nur das Panel des aktuellen Schritts ist sichtbar.
  expect(screen.queryByLabelText('Quellnamespace', { exact: false })).toBeNull();

  await type('Host', 'db.example');
  await type('Datenbank', 'alt');
  await type('Benutzer', 'lesen');
  await fireEvent.click(screen.getByRole('button', { name: 'Verbindung prüfen' }));
  await screen.findByText('Prüfbericht der Quelle');
  expect(screen.getByText('submissions')).toBeTruthy();
  await waitFor(() => expect(next().disabled).toBe(false));

  await fireEvent.click(next());
  await screen.findByRole('heading', { name: 'Zuordnung' });
  expect((screen.getByLabelText('Formular-UUIDs dieses Kunden') as HTMLTextAreaElement).value).toBe(
    formId,
  );
  expect((screen.getByLabelText('Erwarteter Schema-HMAC') as HTMLInputElement).value).toBe(
    'c'.repeat(64),
  );
  // Ohne Namen und Namespace ist der Start gesperrt und der Grund genannt.
  const start = screen.getByRole('button', { name: 'Prüflauf starten' }) as HTMLButtonElement;
  expect(start.disabled).toBe(true);
  expect(screen.getByText(/Noch offen: Kundenname, Quellnamespace/)).toBeTruthy();
  await type('Kundenname', 'Kunde');
  await type('Quellnamespace', 'alt');
  expect(start.disabled).toBe(false);
  await fireEvent.click(back());
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
});

it('sperrt Weiter ohne Quellprüfung', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [] } });
  render(Migration);
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
  expect((screen.getByRole('button', { name: 'Weiter' }) as HTMLButtonElement).disabled).toBe(true);
});

it('springt bei einem laufenden Import selbst in den Import-Schritt', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [
        { id: 'j1', state: 'running', phase: 'anfragen', dryRun: false, error: '', report: {} },
      ],
    },
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Import' });
  expect(screen.getByText('Schritt 3 von 5')).toBeTruthy();
  expect((screen.getByRole('button', { name: 'Weiter' }) as HTMLButtonElement).disabled).toBe(true);
  expect(screen.getByRole('button', { name: 'Sicher pausieren' })).toBeTruthy();
});
