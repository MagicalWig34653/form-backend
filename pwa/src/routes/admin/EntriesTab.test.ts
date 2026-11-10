import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, within } from '@testing-library/svelte';
import ConfirmHost from '$lib/components/shell/ConfirmHost.svelte';
import EntriesTab from './EntriesTab.svelte';

const api = vi.hoisted(() => ({ entries: vi.fn(), retention: vi.fn(), deleteEntries: vi.fn() }));
vi.mock('$lib/api', () => ({ adminApi: api }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: { dataKey: () => null, onLock: () => () => {} },
}));
const entry = {
  id: 'e',
  receivedAt: '2026-11-03T10:00:00Z',
  state: 'accepted',
  held: false,
  keyId: 'k',
  releaseId: null,
};

beforeEach(() => {
  vi.resetAllMocks();
  api.entries.mockResolvedValue({ ok: true, data: { items: [entry], nextCursor: null } });
  api.retention.mockResolvedValue({ ok: true, data: { days: 90 } });
});

describe('EntriesTab metadata states', () => {
  it('shows metadata without decrypted previews and explains missing data access', async () => {
    render(EntriesTab, { tenant: 't', form: 'f' });

    expect(
      await screen.findByText('Für diese Einsendung ist Ihr Datenzugang noch nicht eingerichtet.'),
    ).toBeTruthy();
    expect((screen.getByRole('button', { name: 'Öffnen' }) as HTMLButtonElement).disabled).toBe(
      true,
    );
    await fireEvent.input(screen.getByLabelText('Eingangsdatum (ISO-Datum)'), {
      target: { value: '2020' },
    });
    expect(await screen.findByText('Keine Einsendungen für diese Filter.')).toBeTruthy();
  });
  it('distinguishes empty data from a denied request and permits retry', async () => {
    api.entries.mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 403 } });
    api.entries.mockResolvedValueOnce({ ok: true, data: { items: [], nextCursor: null } });
    render(EntriesTab, { tenant: 't', form: 'f' });
    expect(await screen.findByRole('alert')).toBeTruthy();
    expect(screen.queryByText('Noch keine Einsendungen.')).toBeNull();
    await fireEvent.click(screen.getByRole('button', { name: 'Erneut versuchen' }));
    expect(await screen.findByText('Noch keine Einsendungen.')).toBeTruthy();
  });
  it('keeps a loading state without inventing an empty result', async () => {
    api.entries.mockReturnValue(new Promise(() => {}));
    render(EntriesTab, { tenant: 't', form: 'f' });
    expect(await screen.findByRole('status')).toBeTruthy();
    expect(screen.queryByText('Noch keine Einsendungen.')).toBeNull();
  });
});

it('requires a confirmation and keeps pending deletions visible', async () => {
  api.deleteEntries.mockResolvedValue({
    ok: true,
    data: { deleted: [], held: [], missing: [], pending: ['e'] },
  });
  render(EntriesTab, { tenant: 't', form: 'f' });
  render(ConfirmHost);
  await screen.findByText('Für diese Einsendung ist Ihr Datenzugang noch nicht eingerichtet.');
  await fireEvent.click(screen.getByRole('button', { name: 'Löschen' }));
  const dialog = await screen.findByRole('alertdialog', { name: 'Einsendungen löschen' });
  expect(api.deleteEntries).not.toHaveBeenCalled();
  await fireEvent.click(within(dialog).getByRole('button', { name: 'Endgültig löschen' }));
  expect(await screen.findByText(/Gelöscht: 0.*Noch in Löschung: 1/)).toBeTruthy();
  expect(api.deleteEntries).toHaveBeenCalledWith('t', 'f', ['e']);
  expect(screen.queryByText('Noch keine Einsendungen.')).toBeNull();
});
