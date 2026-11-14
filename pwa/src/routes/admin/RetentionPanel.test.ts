import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { beforeEach, expect, it, vi } from 'vitest';
import RetentionPanel from './RetentionPanel.svelte';
import { confirmState } from '$lib/confirm.svelte';

const api = vi.hoisted(() => ({ retention: vi.fn(), setRetention: vi.fn() }));
vi.mock('$lib/api', () => ({ adminApi: api }));

beforeEach(() => vi.resetAllMocks());

it('zeigt die gespeicherte Frist und den Standard, ohne Option zum Abschalten', async () => {
  api.retention.mockResolvedValue({ ok: true, data: { days: 3 } });
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = (await screen.findByLabelText('Aufbewahrung in Tagen')) as HTMLInputElement;
  expect(input.value).toBe('3');
  expect(screen.getByText(/Standard: 72 Stunden \(3 Tage\)/)).toBeTruthy();
  // no switch / checkbox to turn the deletion off, no "off" text
  expect(screen.queryByRole('switch')).toBeNull();
  expect(screen.queryByLabelText('Einsendungen automatisch löschen')).toBeNull();
  expect(screen.queryByText(/unbegrenzt gespeichert/)).toBeNull();
  expect(screen.queryByText(/keine automatische Löschung/)).toBeNull();
});

it('speichert eine geänderte Frist (3 auf 5) ohne Bestätigung, da nicht verkürzt', async () => {
  api.retention.mockResolvedValue({ ok: true, data: { days: 3 } });
  api.setRetention.mockResolvedValue({ ok: true, data: { days: 5 } });
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '5' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await waitFor(() => expect(api.setRetention).toHaveBeenCalledWith('tenant', 'form', 5));
});

it('sendet nie null: eine leere Eingabe wird abgelehnt', async () => {
  api.retention.mockResolvedValue({ ok: true, data: { days: 3 } });
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await screen.findByText('Bitte eine ganze Zahl zwischen 1 und 3650 eingeben.');
  expect(api.setRetention).not.toHaveBeenCalled();
});

it('zeigt den Grundtext des Servers bei 409 (Import läuft)', async () => {
  const reason =
    'Die Aufbewahrungsfrist kann nicht geändert werden, solange ein Import fortgesetzt werden kann. Import abschließen oder im Umstieg schließen, danach erneut versuchen.';
  api.retention.mockResolvedValue({ ok: true, data: { days: 3 } });
  api.setRetention.mockResolvedValue({
    ok: false,
    error: {
      kind: 'http',
      status: 409,
      code: 'retention_import_running',
      detail: reason,
      message: 'x',
    },
  });
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '5' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await screen.findByText(reason);
});

it('importierte Einsendungen: zeigt die sofort fälligen, verlangt Häkchen und Bestätigung', async () => {
  api.retention.mockResolvedValue({
    ok: true,
    data: { days: 3, importedCount: 5, importedWithoutDeadline: 5 },
  });
  api.setRetention.mockImplementation(
    async (_t: string, _f: string, d: number, o?: { dryRun?: boolean }) => ({
      ok: true,
      data: { days: d, importedWithoutDeadline: o?.dryRun ? 5 : 0, dueNowImported: 4 },
    }),
  );
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '30' } });
  await screen.findByText(/wären 4 importierte Einsendungen sofort fällig/);
  expect(api.setRetention).toHaveBeenCalledWith('tenant', 'form', 30, { dryRun: true });
  // without the checkbox the period is saved WITHOUT touching imported submissions
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await waitFor(() => expect(api.setRetention).toHaveBeenCalledWith('tenant', 'form', 30));
});

it('importierte Einsendungen: mit Häkchen wird applyToImported erst nach Bestätigung gesendet', async () => {
  api.retention.mockResolvedValue({
    ok: true,
    data: { days: 3, importedCount: 5, importedWithoutDeadline: 5 },
  });
  api.setRetention.mockImplementation(
    async (_t: string, _f: string, d: number, o?: { dryRun?: boolean }) => ({
      ok: true,
      data: { days: d, importedWithoutDeadline: o?.dryRun ? 5 : 0, dueNowImported: 4 },
    }),
  );
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '30' } });
  await fireEvent.click(
    await screen.findByLabelText('Frist auch auf die importierten Einsendungen anwenden'),
  );
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await waitFor(() => expect(confirmState.current?.confirmLabel).toBe('Anwenden und löschen'));
  expect(confirmState.current?.description).toContain('4 importierte Einsendungen');
  expect(api.setRetention).not.toHaveBeenCalledWith('tenant', 'form', 30, {
    applyToImported: true,
  });
  confirmState.settle(true);
  await waitFor(() =>
    expect(api.setRetention).toHaveBeenCalledWith('tenant', 'form', 30, { applyToImported: true }),
  );
});

it('Verkürzen mit Häkchen zeigt genau EINEN zusammengefassten Dialog mit beiden Folgen (1698259A)', async () => {
  api.retention.mockResolvedValue({
    ok: true,
    data: { days: 30, importedCount: 5, importedWithoutDeadline: 5 },
  });
  api.setRetention.mockImplementation(
    async (_t: string, _f: string, d: number, o?: { dryRun?: boolean }) => ({
      ok: true,
      data: { days: d, importedWithoutDeadline: o?.dryRun ? 5 : 0, dueNowImported: 4 },
    }),
  );
  render(RetentionPanel, { tenant: 'tenant', form: 'form' });
  const input = await screen.findByLabelText('Aufbewahrung in Tagen');
  await fireEvent.input(input, { target: { value: '10' } });
  await fireEvent.click(
    await screen.findByLabelText('Frist auch auf die importierten Einsendungen anwenden'),
  );
  await fireEvent.click(screen.getByRole('button', { name: 'Aufbewahrung speichern' }));
  await waitFor(() => expect(confirmState.current).toBeTruthy());
  expect(confirmState.current?.description).toContain('älter als 10 Tage');
  expect(confirmState.current?.description).toContain('4 importierte Einsendungen');
  expect(api.setRetention).not.toHaveBeenCalledWith('tenant', 'form', 10, {
    applyToImported: true,
  });
  confirmState.settle(true);
  await waitFor(() =>
    expect(api.setRetention).toHaveBeenCalledWith('tenant', 'form', 10, { applyToImported: true }),
  );
  // no second dialog
  expect(confirmState.current).toBeFalsy();
});
