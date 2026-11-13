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
  // Formulare, Namespace und Schema-HMAC kommen ohne Eingabe aus der Quellprüfung.
  expect(screen.getByTestId('migration-forms').textContent).toContain(formId);
  expect(
    (screen.getByLabelText('Quellnamespace', { exact: false }) as HTMLInputElement).value,
  ).toBe('legacy-alt');
  expect((screen.getByLabelText('Erwarteter Schema-HMAC') as HTMLInputElement).value).toBe(
    'c'.repeat(64),
  );
  // Nur der Kundenname fehlt; der Start ist gesperrt und der Grund genannt.
  const start = screen.getByRole('button', { name: 'Prüflauf starten' }) as HTMLButtonElement;
  expect(start.disabled).toBe(true);
  expect(screen.getByText(/Noch offen: Kundenname\./)).toBeTruthy();
  await type('Kundenname', 'Kunde');
  expect(start.disabled).toBe(false);
  // Geänderte Verbindungsangaben verlangen eine neue Prüfung.
  await fireEvent.click(back());
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
  await type('Datenbank', 'andere');
  await fireEvent.click(next());
  await screen.findByRole('heading', { name: 'Zuordnung' });
  expect(screen.getByText(/Noch offen: erneute Quellprüfung/)).toBeTruthy();
  expect(
    (screen.getByRole('button', { name: 'Prüflauf starten' }) as HTMLButtonElement).disabled,
  ).toBe(true);
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

it('verlangt bei mehreren Kunden eine Kundenwahl je nicht ableitbarem Schlüssel', async () => {
  const kid = 'aaaaaaaaaaaaaaaa';
  request.mockImplementation(async (method, path) => {
    if (method === 'GET') return { ok: true, data: { items: [] } };
    if (path === '/migration/test')
      return {
        ok: true,
        data: {
          schemaHMAC: 'c'.repeat(64),
          formIds: [formId],
          counts: {},
          keys: [{ kid, status: 'aktiv', createdAt: 1700000000, publicKeyValid: true }],
          keyUsage: { complete: true, scannedSubmissions: 0, items: [] },
        },
      };
    return { ok: true, data: {} };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
  await type('Host', 'db.example');
  await type('Datenbank', 'alt');
  await type('Benutzer', 'lesen');
  await fireEvent.click(screen.getByRole('button', { name: 'Verbindung prüfen' }));
  await screen.findByText('Prüfbericht der Quelle');
  await fireEvent.click(screen.getByRole('button', { name: 'Weiter' }));
  await screen.findByRole('heading', { name: 'Zuordnung' });
  await fireEvent.click(screen.getByRole('button', { name: 'Weiteren Kunden hinzufügen' }));
  await type('Kundenname (Kunde 1)', 'A');
  await type('Kundenname (Kunde 2)', 'B');
  const start = screen.getByRole('button', { name: 'Prüflauf starten' }) as HTMLButtonElement;
  expect(start.disabled).toBe(true);
  expect(screen.getByText(/Noch offen: Kunde je Schlüssel/)).toBeTruthy();
  const select = screen.getByLabelText(`Kunde für kid ${kid}`) as HTMLSelectElement;
  await fireEvent.change(select, { target: { value: select.options[2]!.value } });
  await waitFor(() => expect(start.disabled).toBe(false));
});

it('weist im Umstieg auf Mailserver hin, deren Zertifikatsprüfung abgeschaltet übernommen wird', async () => {
  const flagged = '44444444-4444-4444-8444-444444444442';
  const normal = '44444444-4444-4444-8444-444444444441';
  request.mockImplementation(async (method, path) => {
    if (method === 'GET') return { ok: true, data: { items: [] } };
    if (path === '/migration/test')
      return {
        ok: true,
        data: {
          schemaHMAC: 'c'.repeat(64),
          formIds: [formId],
          connectionIds: [normal, flagged],
          connections: [
            { id: normal, kind: 'smtp', name: 'Geprüft' },
            { id: flagged, kind: 'smtp', name: 'Eigenes Zertifikat', verifyCertificateOff: true },
          ],
          counts: { submissions: 1 },
        },
      };
    return { ok: true, data: {} };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Quelle prüfen' });
  await type('Host', 'db.example');
  await type('Datenbank', 'alt');
  await type('Benutzer', 'lesen');
  await fireEvent.click(screen.getByRole('button', { name: 'Verbindung prüfen' }));
  await screen.findByText('Prüfbericht der Quelle');
  await waitFor(() =>
    expect((screen.getByRole('button', { name: 'Weiter' }) as HTMLButtonElement).disabled).toBe(
      false,
    ),
  );
  await fireEvent.click(screen.getByRole('button', { name: 'Weiter' }));
  await screen.findByRole('heading', { name: 'Zuordnung' });
  expect(
    screen.getAllByText(/Zertifikatsprüfung für diesen Mailserver abgeschaltet übernommen/),
  ).toHaveLength(1);
});
