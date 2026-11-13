import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import { t } from '$lib/i18n';
import ScopePicker from './ScopePicker.svelte';

const forms = vi.hoisted(() => vi.fn());
const state = vi.hoisted(() => ({ tenants: [] as { id: string; name: string }[] }));
vi.mock('$lib/api', () => ({ adminApi: { forms } }));
vi.mock('$lib/session.svelte', () => ({
  session: {
    get tenants() {
      return state.tenants;
    },
  },
}));
const text = t.admin.tokens;

beforeEach(() => {
  forms.mockReset();
  state.tenants = [];
});

it('fällt ohne Kundenliste auf Eingabefelder für die Kennungen zurück', () => {
  render(ScopePicker, { idPrefix: 'p' });
  expect(screen.getByLabelText(/Kunden-ID/)).toBeTruthy();
  expect(forms).not.toHaveBeenCalled();
});
it('wählt Kunden und Formulare nach Namen und lädt Formulare des Kunden', async () => {
  state.tenants = [
    { id: 't1', name: 'Kunde A' },
    { id: 't2', name: 'Kunde B' },
  ];
  forms.mockResolvedValue({ ok: true, data: { items: [{ id: 'f1', name: 'Kontakt' }] } });
  render(ScopePicker, { idPrefix: 'p', tenantId: 't1' });
  await waitFor(() => expect(forms).toHaveBeenCalledWith('t1'));
  expect(await screen.findByRole('option', { name: 'Kontakt' })).toBeTruthy();
  expect(screen.getByRole('option', { name: text.allForms })).toBeTruthy();
});
it('setzt die Formularauswahl zurück, wenn der Kunde wechselt', async () => {
  state.tenants = [
    { id: 't1', name: 'Kunde A' },
    { id: 't2', name: 'Kunde B' },
  ];
  forms.mockResolvedValue({ ok: true, data: { items: [{ id: 'f1', name: 'Kontakt' }] } });
  render(ScopePicker, { idPrefix: 'p', tenantId: 't1', formId: 'f1' });
  await screen.findByRole('option', { name: 'Kontakt' });
  const tenant = screen.getByLabelText(new RegExp(`^${text.tenantPick}`)) as HTMLSelectElement;
  await fireEvent.change(tenant, { target: { value: 't2' } });
  await waitFor(() => expect(forms).toHaveBeenCalledWith('t2'));
  const form = screen.getByLabelText(new RegExp(`^${text.formPick}`)) as HTMLSelectElement;
  expect(form.value).toBe('');
});
it('meldet ein Ladeproblem der Formulare', async () => {
  state.tenants = [{ id: 't1', name: 'Kunde A' }];
  forms.mockResolvedValue({ ok: false, error: { kind: 'network' } });
  render(ScopePicker, { idPrefix: 'p', tenantId: 't1' });
  expect(await screen.findByText(text.formsFailed)).toBeTruthy();
});
