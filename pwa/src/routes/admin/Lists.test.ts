import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import Forms from './Forms.svelte';
import Tenants from './Tenants.svelte';
import OverviewTab from './OverviewTab.svelte';
import type { Editor } from '$lib/draft/editor.svelte';
const mocks = vi.hoisted(() => ({
  forms: vi.fn(),
  tenants: vi.fn(),
  createTenant: vi.fn(),
  createForm: vi.fn(),
  ensureCustomer: vi.fn(),
  request: vi.fn(),
  statistics: vi.fn(),
  navigate: vi.fn(),
  session: {
    me: { systemAdministrator: true },
    tenants: [{ id: 'a', name: 'Beispiel', permissions: ['form.create'] }],
    refreshTenants: vi.fn(),
  },
}));
vi.mock('$lib/api', () => ({ adminApi: mocks, http: { request: mocks.request } }));
vi.mock('$lib/session.svelte', () => ({ session: mocks.session }));
vi.mock('$lib/crypto/automation.svelte', () => ({
  accessAutomation: { ensureCustomer: mocks.ensureCustomer },
}));
vi.mock('$lib/router.svelte', () => ({ router: { navigate: mocks.navigate } }));
vi.mock('$lib/admin/guard.svelte', () => ({
  handleSessionError: () => false,
  reauthenticate: vi.fn(),
}));
vi.mock('./AccessStatus.svelte', () => ({ default: () => {} }));
beforeEach(() => {
  vi.clearAllMocks();
  mocks.session.me.systemAdministrator = true;
  mocks.session.tenants[0]!.permissions = ['form.create'];
  mocks.forms.mockResolvedValue({
    ok: true,
    data: {
      items: [
        { id: 'f', name: 'Kontakt', active: true, currentReleaseId: 'r' },
        { id: 'g', name: 'Anfrage', active: false, currentReleaseId: null },
      ],
      nextCursor: null,
    },
  });
  mocks.tenants.mockResolvedValue({ ok: true, data: { items: mocks.session.tenants } });
  mocks.ensureCustomer.mockResolvedValue(undefined);
});
it('filtert Namen und Status und setzt Filter zurück', async () => {
  render(Forms, { tenant: 'a' });
  await screen.findByRole('link', { name: 'Kontakt' });
  await fireEvent.change(screen.getByLabelText('Status'), { target: { value: 'unpublished' } });
  expect(screen.queryByRole('link', { name: 'Kontakt' })).toBeNull();
  await fireEvent.input(screen.getByLabelText('Formulare suchen'), { target: { value: 'nichts' } });
  expect(screen.getByText('Keine passenden Formulare.')).toBeTruthy();
  await fireEvent.click(screen.getByText('Filter zurücksetzen'));
  expect(screen.getByRole('link', { name: 'Kontakt' })).toBeTruthy();
});
it('zeigt Fehler statt leer oder endlos laden und erlaubt Retry', async () => {
  mocks.forms.mockResolvedValueOnce({ ok: false, error: { status: 503 } });
  render(Forms, { tenant: 'a' });
  expect((await screen.findByRole('alert')).textContent).toContain('nicht geladen');
  expect(screen.queryByText('Dieser Kunde hat noch kein Formular.')).toBeNull();
  await fireEvent.click(screen.getByText('Erneut versuchen'));
  await screen.findByRole('link', { name: 'Kontakt' });
});
it('blendet Anlage ohne effektives Kundenrecht aus und erklärt 403', async () => {
  mocks.session.tenants[0]!.permissions = [];
  mocks.forms.mockResolvedValueOnce({ ok: false, error: { status: 403 } });
  render(Forms, { tenant: 'a' });
  expect((await screen.findByRole('alert')).textContent).toContain('Berechtigung');
  expect(screen.queryByRole('button', { name: 'Formular anlegen' })).toBeNull();
});
it('lädt weitere Seite mit Cursor und erhält den Suchfilter', async () => {
  mocks.forms.mockResolvedValueOnce({ ok: true, data: { items: [], nextCursor: 'c+=' } });
  mocks.request.mockResolvedValueOnce({
    ok: true,
    data: {
      items: [{ id: 'f', name: 'Kontakt', active: true, currentReleaseId: null }],
      nextCursor: null,
    },
  });
  render(Forms, { tenant: 'a' });
  await screen.findByText('Weitere laden');
  await fireEvent.input(screen.getByLabelText('Formulare suchen'), {
    target: { value: 'Kontakt' },
  });
  await fireEvent.click(screen.getByText('Weitere laden'));
  await screen.findByRole('link', { name: 'Kontakt' });
  expect(mocks.request.mock.calls[0]?.[1]).toContain('cursor=c%2B%3D');
});
it('unterscheidet fehlende Freigabe von leerer Kundenverwaltung', async () => {
  mocks.session.me.systemAdministrator = false;
  mocks.tenants.mockResolvedValueOnce({ ok: true, data: { items: [] } });
  render(Tenants);
  await screen.findByText('Für Ihr Konto ist noch kein Kunde freigegeben.');
  expect(screen.queryByRole('button', { name: 'Kunde anlegen' })).toBeNull();
});
it('zeigt Kundenrechte als einzelne Chips', async () => {
  render(Tenants);
  await screen.findByRole('link', { name: 'Öffnen: Beispiel' });
  const chips = screen.getAllByTestId('rights-chips')[0]!;
  expect(chips.querySelectorAll('li').length).toBeGreaterThan(0);
  expect(chips.tagName).toBe('UL');
});
it('behält einen einzelnen Kunden in der Übersicht sichtbar', async () => {
  render(Tenants);
  await screen.findByRole('link', { name: 'Öffnen: Beispiel' });
  expect(mocks.navigate).not.toHaveBeenCalled();
});
it('setzt nach Vorbereitungsfehler denselben Kunden fort ohne zweiten POST', async () => {
  mocks.createTenant.mockResolvedValue({ ok: true, data: { id: 'new' } });
  mocks.ensureCustomer.mockRejectedValueOnce(new Error('Vorbereitung fehlgeschlagen'));
  render(Tenants);
  await screen.findByText('Beispiel');
  await fireEvent.click(screen.getByRole('button', { name: 'Kunde anlegen' }));
  await fireEvent.input(screen.getByLabelText('Name des Kunden'), { target: { value: 'Neu' } });
  await fireEvent.submit(screen.getByLabelText('Name des Kunden').closest('form')!);
  await screen.findByText('Einrichtung unvollständig');
  await fireEvent.click(screen.getByRole('button', { name: 'Einrichtung fortsetzen' }));
  await waitFor(() => expect(mocks.navigate).toHaveBeenCalledWith('/t/new'));
  expect(mocks.createTenant).toHaveBeenCalledTimes(1);
  expect(mocks.ensureCustomer).toHaveBeenNthCalledWith(2, 'new');
});
it('springt nach dem Anlegen nicht mehr zum Kunden, wenn die Liste schon verlassen wurde (Umstieg-Formular blieb sonst nicht stehen)', async () => {
  // The new customer's preparation (keys) is slow; meanwhile the user opened the customer or another page. A late navigate() would
  // pull them back (seen live: the Umstieg form was removed from under the user 60 ms after opening it).
  let finish!: () => void;
  mocks.createTenant.mockResolvedValue({ ok: true, data: { id: 'new' } });
  mocks.ensureCustomer.mockReturnValueOnce(new Promise<void>((done) => (finish = done)));
  const view = render(Tenants);
  await screen.findByText('Beispiel');
  await fireEvent.click(screen.getByRole('button', { name: 'Kunde anlegen' }));
  await fireEvent.input(screen.getByLabelText('Name des Kunden'), { target: { value: 'Neu' } });
  await fireEvent.submit(screen.getByLabelText('Name des Kunden').closest('form')!);
  await waitFor(() => expect(mocks.ensureCustomer).toHaveBeenCalledWith('new'));
  view.unmount(); // the user left the customer list
  finish();
  await waitFor(() => expect(mocks.session.refreshTenants).toHaveBeenCalled());
  await new Promise((r) => setTimeout(r, 20));
  expect(mocks.navigate).not.toHaveBeenCalled();
});
it('springt nach dem Anlegen eines Formulars nicht mehr zurück, wenn die Liste schon verlassen wurde', async () => {
  let finish!: (value: unknown) => void;
  mocks.createForm.mockReturnValueOnce(new Promise((done) => (finish = done)));
  const view = render(Forms, { tenant: 'a' });
  await screen.findByRole('link', { name: 'Kontakt' });
  await fireEvent.click(screen.getByRole('button', { name: 'Formular anlegen' }));
  await fireEvent.input(screen.getByLabelText('Name des Formulars'), { target: { value: 'Neu' } });
  await fireEvent.submit(screen.getByLabelText('Name des Formulars').closest('form')!);
  await waitFor(() => expect(mocks.createForm).toHaveBeenCalled());
  view.unmount();
  finish({ ok: true, data: { id: 'nf' } });
  await new Promise((r) => setTimeout(r, 20));
  expect(mocks.navigate).not.toHaveBeenCalled();
});
it('zeigt unveröffentlichten Formularstatus auch bei Statistikfehler', async () => {
  mocks.statistics.mockResolvedValue({ ok: false, error: { status: 403 } });
  const editor = {
    detail: { active: false, currentReleaseId: null, currentReleaseVersion: null },
    draft: null,
    error: null,
    saving: false,
  } as unknown as Editor;
  render(OverviewTab, { editor, tenant: 'a', form: 'f' });
  await screen.findByText('Dafür fehlt Ihnen die Berechtigung.');
  expect(
    screen.getByText(
      'Noch nicht veröffentlicht. Dieses Formular nimmt noch keine Einsendungen an.',
    ),
  ).toBeTruthy();
  expect(screen.queryByText('0 %')).toBeNull();
});
it('kündigt langsames Laden an und reserviert Platz', async () => {
  vi.useFakeTimers();
  mocks.forms.mockReturnValueOnce(new Promise(() => {}));
  const view = render(Forms, { tenant: 'a' });
  try {
    expect(view.container.querySelector('[aria-busy="true"]')).toBeTruthy();
    await vi.advanceTimersByTimeAsync(3000);
    expect(screen.getByRole('status').textContent).toContain('dauert länger');
  } finally {
    view.unmount();
    vi.useRealTimers();
  }
});
it('ignoriert verspätete Antworten nach dem Kundenwechsel', async () => {
  let resolve!: (value: unknown) => void;
  mocks.forms.mockReturnValueOnce(
    new Promise((done) => {
      resolve = done;
    }),
  );
  const first = render(Forms, { tenant: 'a' });
  first.unmount();
  render(Forms, { tenant: 'b' });
  await screen.findByRole('link', { name: 'Kontakt' });
  resolve({ ok: true, data: { items: [{ id: 'old', name: 'Alter Kunde' }], nextCursor: null } });
  await Promise.resolve();
  expect(screen.queryByText('Alter Kunde')).toBeNull();
});
