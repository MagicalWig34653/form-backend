import { render, screen, fireEvent } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Migration from './Migration.svelte';
const request = vi.hoisted(() => vi.fn());
vi.mock('$lib/api', () => ({
  http: { request },
  adminApi: { tenants: async () => ({ ok: true, data: { items: [] } }) },
}));
vi.mock('$lib/admin/guard.svelte', () => ({ reauthenticate: vi.fn() }));
beforeEach(() => request.mockReset());

const reviewJob = (over: Record<string, unknown> = {}) => ({
  id: 'j1',
  state: 'review',
  phase: 'done',
  dryRun: false,
  error: '',
  report: {},
  probeConfirmed: false,
  testConfirmed: false,
  ...over,
});

it('sperrt Altzugriff entfernen ohne Bestätigungen und nennt, was fehlt', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [reviewJob()] } });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  await fireEvent.click(screen.getByRole('button', { name: 'Weiter' }));
  await screen.findByRole('heading', { name: 'Umschaltung' });
  const remove = screen.getByRole('button', { name: 'Altzugriff entfernen' }) as HTMLButtonElement;
  expect(remove.disabled).toBe(true);
  expect(screen.getByText(/Noch offen: Probe, Testnachricht\./)).toBeTruthy();
});

it('gibt Altzugriff entfernen nach beiden Bestätigungen frei', async () => {
  request.mockResolvedValue({
    ok: true,
    data: { items: [reviewJob({ probeConfirmed: true, testConfirmed: true })] },
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  await fireEvent.click(screen.getByRole('button', { name: 'Weiter' }));
  await screen.findByRole('heading', { name: 'Umschaltung' });
  expect(
    (screen.getByRole('button', { name: 'Altzugriff entfernen' }) as HTMLButtonElement).disabled,
  ).toBe(false);
  expect(screen.queryByText(/Noch offen: Probe/)).toBeNull();
});

it('meldet 409 als Zustandskonflikt, nicht als Verbindungsabbruch', async () => {
  request.mockImplementation(async (method, path) => {
    if (method === 'GET' && path === '/migration/jobs')
      return { ok: true, data: { items: [reviewJob()] } };
    return { ok: false, error: { status: 409, code: 'conflict' } };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  await fireEvent.click(screen.getByRole('button', { name: 'Entschlüsselungsprobe laden' }));
  const alert = await screen.findByRole('alert');
  expect(alert.textContent).toContain('im aktuellen Zustand des Laufs nicht möglich');
  expect(alert.textContent).not.toContain('unterbrochen');
});

it('zeigt nach der Probe die benötigte Schlüssel-ID', async () => {
  request.mockImplementation(async (method, path) => {
    if (path === '/migration/jobs/j1/probe')
      return {
        ok: true,
        data: { wire: 'KUBUS-AEAD:2|d19bf3f082782c87|hpke|a:b|c|d|e', hash: 'a'.repeat(64) },
      };
    return { ok: true, data: { items: [reviewJob()] } };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  await fireEvent.click(screen.getByRole('button', { name: 'Entschlüsselungsprobe laden' }));
  await screen.findByLabelText('Privater Altschlüssel');
  expect(screen.getByTestId('migration-probe-kid').textContent).toContain('d19bf3f082782c87');
});

it('zeigt nach dem Abschluss den Zustand Umstieg abgeschlossen ohne Aktionen', async () => {
  request.mockResolvedValue({
    ok: true,
    data: {
      items: [reviewJob({ state: 'closed', probeConfirmed: true, testConfirmed: true })],
    },
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Umschaltung' });
  const done = await screen.findByTestId('migration-closed');
  expect(done.textContent).toContain('Umstieg abgeschlossen');
  expect(done.textContent).toContain('Zugangsdaten zur Quelle sind entfernt');
  expect(screen.queryByRole('button', { name: 'Altzugriff entfernen' })).toBeNull();
  expect(screen.queryByText('Vor der Umschaltung prüfen')).toBeNull();
});
