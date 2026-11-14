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

it('sperrt das Freigeben vor der Entschlüsselungsprobe und nennt den Grund', async () => {
  request.mockResolvedValue({ ok: true, data: { items: [reviewJob()] } });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  const button = screen.getByRole('button', {
    name: 'Importierte Einsendungen freigeben',
  }) as HTMLButtonElement;
  expect(button.disabled).toBe(true);
  expect(screen.getByText(/Erst nach bestandener Entschlüsselungsprobe/)).toBeTruthy();
});

it('gibt nach der Probe frei und zeigt freigegebene und verbleibende Einsendungen', async () => {
  request.mockImplementation(async (method, path) => {
    if (method === 'GET' && path === '/migration/jobs')
      return { ok: true, data: { items: [reviewJob({ probeConfirmed: true })] } };
    if (method === 'POST' && path === '/migration/jobs/j1/release-submissions')
      return { ok: true, data: { status: 'accepted', released: 7, newlyReleased: 7, kept: 2 } };
    return { ok: false, error: { status: 404 } };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Prüfung' });
  const button = screen.getByRole('button', {
    name: 'Importierte Einsendungen freigeben',
  }) as HTMLButtonElement;
  expect(button.disabled).toBe(false);
  await fireEvent.click(button);
  expect(await screen.findByText('7 freigegeben, 2 bleiben in der Prüfung.')).toBeTruthy();
  expect(request).toHaveBeenCalledWith('POST', '/migration/jobs/j1/release-submissions', {
    body: undefined,
  });
});

it('akzeptiert Prüffälle nur mit Begründung und sendet sie an den Server', async () => {
  request.mockImplementation(async (method, path) => {
    if (method === 'GET' && path === '/migration/jobs')
      return { ok: true, data: { items: [reviewJob({ probeConfirmed: true })] } };
    if (method === 'POST' && path === '/migration/jobs/j1/accept-review')
      return { ok: true, data: { status: 'accepted', accepted: 4 } };
    return { ok: false, error: { status: 404 } };
  });
  render(Migration);
  await screen.findByRole('heading', { name: 'Offene Prüffälle akzeptieren' });
  const button = screen.getByRole('button', { name: 'Prüffälle akzeptieren' }) as HTMLButtonElement;
  expect(button.disabled).toBe(true);
  const reason = screen.getByLabelText('Begründung (8 bis 200 Zeichen)');
  await fireEvent.input(reason, { target: { value: 'kurz' } });
  expect(button.disabled).toBe(true);
  await fireEvent.input(reason, { target: { value: '  Betreiber hat die Anhänge geprüft  ' } });
  expect(button.disabled).toBe(false);
  await fireEvent.click(button);
  expect(await screen.findByText('4 Prüffälle akzeptiert.')).toBeTruthy();
  expect(request).toHaveBeenCalledWith('POST', '/migration/jobs/j1/accept-review', {
    body: { reason: 'Betreiber hat die Anhänge geprüft' },
  });
});
