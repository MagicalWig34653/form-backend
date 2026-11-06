import { beforeEach, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';
import Suche from './Suche.svelte';
const mock = vi.hoisted(() => ({
  scan: vi.fn(),
  access: vi.fn(),
  deleteEntries: vi.fn(),
  lock: undefined as (() => void) | undefined,
}));
vi.mock('$lib/export/service', async (importOriginal) => ({
  ...(await importOriginal<object>()),
  scan: mock.scan,
  access: mock.access,
}));
vi.mock('$lib/api', () => ({ adminApi: mock, http: { request: vi.fn() } }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: {
    onLock: (fn: () => void) => {
      mock.lock = fn;
      return () => {};
    },
  },
}));
beforeEach(() => {
  vi.resetAllMocks();
  mock.scan.mockResolvedValue([
    { id: 'person-hit', receivedAt: null, fields: { name: 'Synthetic Person' }, unreadable: false },
    { id: 'unknown', receivedAt: null, fields: {}, unreadable: true },
    { id: 'other', receivedAt: null, fields: { name: 'Other' }, unreadable: false },
  ]);
  mock.access.mockResolvedValue({ canExport: true, canDelete: true });
});
it('filters locally, confirms deletion and excludes unknown candidates from deletion', async () => {
  const deleted = vi.fn();
  mock.deleteEntries.mockResolvedValue({
    ok: true,
    data: { deleted: ['person-hit'], held: [], missing: [] },
  });
  render(Suche, { tenant: 't', form: 'f', onDeleted: deleted });
  await fireEvent.input(screen.getByLabelText('Person oder Suchbegriff'), {
    target: { value: 'Person' },
  });
  await fireEvent.click(screen.getByText('Lokal durchsuchen'));
  expect(await screen.findByText('Treffer und ungeklärte Datensätze: 2')).toBeTruthy();
  expect(screen.queryByText(/"Other"/)).toBeNull();
  await fireEvent.click(screen.getByText('Alle sichtbaren Ergebnisse auswählen'));
  await fireEvent.click(screen.getByText('Ausgewählte Treffer löschen'));
  expect(mock.deleteEntries).not.toHaveBeenCalled();
  await fireEvent.click(screen.getByText('Treffer endgültig löschen'));
  expect(mock.deleteEntries).toHaveBeenCalledWith('t', 'f', ['person-hit']);
  expect(deleted).toHaveBeenCalledWith(['person-hit']);
  expect(await screen.findByText('Nicht entschlüsselbar – Zugehörigkeit ungeklärt')).toBeTruthy();
});
it('checks delete permission live again after confirmation', async () => {
  render(Suche, { tenant: 't', form: 'f', onDeleted: vi.fn() });
  await fireEvent.click(screen.getByText('Lokal durchsuchen'));
  await screen.findByText('Treffer und ungeklärte Datensätze: 3');
  await fireEvent.click(screen.getByText('Alle sichtbaren Ergebnisse auswählen'));
  await fireEvent.click(screen.getByText('Ausgewählte Treffer löschen'));
  mock.access.mockResolvedValue({ canExport: true, canDelete: false });
  await fireEvent.click(screen.getByText('Treffer endgültig löschen'));
  expect(mock.deleteEntries).not.toHaveBeenCalled();
  expect(await screen.findByRole('alert')).toBeTruthy();
});
