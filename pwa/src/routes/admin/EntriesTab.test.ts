import { beforeEach, describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, within } from '@testing-library/svelte';
import ConfirmHost from '$lib/components/shell/ConfirmHost.svelte';
import EntriesTab from './EntriesTab.svelte';

const api = vi.hoisted(() => ({ entries: vi.fn(), retention: vi.fn(), deleteEntries: vi.fn() }));
vi.mock('$lib/api', () => ({ adminApi: api }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: { dataKey: () => null, unlocked: true, onLock: () => () => {} },
}));
const entry = {
  id: 'e',
  receivedAt: '2026-11-03T10:00:00Z',
  state: 'accepted',
  held: false,
  keyId: 'k',
  releaseId: null,
};

async function openMenu(): Promise<void> {
  const trigger = await screen.findByRole('button', { name: /Aktionen für Einsendung/ });
  await fireEvent.keyDown(trigger, { key: 'Enter' });
  await screen.findByRole('menu');
}

beforeEach(() => {
  vi.resetAllMocks();
  api.entries.mockResolvedValue({ ok: true, data: { items: [entry], nextCursor: null } });
  api.retention.mockResolvedValue({ ok: true, data: { days: 90 } });
});

describe('EntriesTab metadata states', () => {
  it('shows metadata without decrypted previews and explains missing data access', async () => {
    render(EntriesTab, { tenant: 't', form: 'f' });

    expect(await screen.findByText(/Für 1 Einsendungen ist Ihr Datenzugang/)).toBeTruthy();
    await openMenu();
    expect(screen.getByRole('menuitem', { name: 'Öffnen' }).getAttribute('aria-disabled')).toBe(
      'true',
    );
    await fireEvent.keyDown(document.activeElement ?? document.body, { key: 'Escape' });
    await fireEvent.input(screen.getByLabelText('Eingang von (UTC)'), {
      target: { value: '01.01.2027' },
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

it('filters by German dates and keeps the API ISO date internal', async () => {
  render(EntriesTab, { tenant: 't', form: 'f' });
  const from = await screen.findByLabelText('Eingang von (UTC)');
  await fireEvent.input(from, { target: { value: '03.11.2026' } });
  expect(screen.queryByText('Keine Einsendungen für diese Filter.')).toBeNull();
  await fireEvent.input(screen.getByLabelText('Eingang bis (UTC)'), {
    target: { value: '02.11.2026' },
  });
  expect(await screen.findByText('Keine Einsendungen für diese Filter.')).toBeTruthy();
  await fireEvent.input(screen.getByLabelText('Eingang bis (UTC)'), {
    target: { value: '03.11.2026' },
  });
  expect(screen.queryByText('Keine Einsendungen für diese Filter.')).toBeNull();
});

it('requires a confirmation and keeps pending deletions visible', async () => {
  api.deleteEntries.mockResolvedValue({
    ok: true,
    data: { deleted: [], held: [], missing: [], pending: ['e'] },
  });
  render(EntriesTab, { tenant: 't', form: 'f' });
  render(ConfirmHost);
  await openMenu();
  await fireEvent.click(await screen.findByRole('menuitem', { name: 'Löschen' }));
  const dialog = await screen.findByRole('alertdialog', { name: 'Einsendungen löschen' });
  expect(api.deleteEntries).not.toHaveBeenCalled();
  await fireEvent.click(within(dialog).getByRole('button', { name: 'Endgültig löschen' }));
  expect(await screen.findByText(/Gelöscht: 0.*Noch in Löschung: 1/)).toBeTruthy();
  expect(api.deleteEntries).toHaveBeenCalledWith('t', 'f', ['e']);
  expect(screen.queryByText('Noch keine Einsendungen.')).toBeNull();
});
