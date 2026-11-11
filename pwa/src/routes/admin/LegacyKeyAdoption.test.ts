import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
vi.mock('$lib/session.svelte', () => ({ session: { me: { id: 'me' } } }));
import LegacyKeyAdoption from './LegacyKeyAdoption.svelte';
import { keyring } from '$lib/crypto/keyring.svelte';

const key = 'A'.repeat(42) + 'E';
beforeEach(() => {
  keyring.unlocked = true;
});
afterEach(() => {
  keyring.lock();
  vi.restoreAllMocks();
});

it('leert das Feld sofort, übergibt 32 Byte und zeigt Erfolg mit kid', async () => {
  const seen: number[][] = [];
  const adopt = vi.spyOn(keyring, 'adoptLegacyKey').mockImplementation(async (_t, _a, secret) => {
    seen.push([...secret]);
    return { kid: '0123456789abcdef' };
  });
  render(LegacyKeyAdoption, { tenant: 't1' });
  const input = screen.getByLabelText(/Alter privater Datenschlüssel/) as HTMLInputElement;
  expect(input.type).toBe('password');
  expect(input.getAttribute('autocomplete')).toBe('off');
  expect(input.getAttribute('spellcheck')).toBe('false');
  await fireEvent.input(input, { target: { value: key } });
  await fireEvent.submit(input.closest('form')!);
  expect(input.value).toBe('');
  await waitFor(() => expect(screen.getByText(/0123456789abcdef/)).toBeTruthy());
  expect(adopt).toHaveBeenCalledWith('t1', 'me', expect.any(Uint8Array));
  expect(seen[0]!.length).toBe(32);
  // the buffer handed over is wiped afterwards
  const buffer = adopt.mock.calls[0]![2];
  expect(buffer.every((b) => b === 0)).toBe(true);
});

it('ungültiges Format: kein Aufruf, Hinweis ohne den Eingabewert', async () => {
  const adopt = vi.spyOn(keyring, 'adoptLegacyKey');
  render(LegacyKeyAdoption, { tenant: 't1' });
  const input = screen.getByLabelText(/Alter privater Datenschlüssel/) as HTMLInputElement;
  await fireEvent.input(input, { target: { value: 'kein-schluessel' } });
  await fireEvent.submit(input.closest('form')!);
  expect(adopt).not.toHaveBeenCalled();
  expect(input.value).toBe('');
  expect(await screen.findByText(/kein privater X25519-Schlüssel/)).toBeTruthy();
  expect(document.body.textContent).not.toContain('kein-schluessel');
});

it('nicht passender Schlüssel: verständliche Meldung', async () => {
  vi.spyOn(keyring, 'adoptLegacyKey').mockResolvedValue('mismatch');
  render(LegacyKeyAdoption, { tenant: 't1' });
  const input = screen.getByLabelText(/Alter privater Datenschlüssel/) as HTMLInputElement;
  await fireEvent.input(input, { target: { value: key } });
  await fireEvent.submit(input.closest('form')!);
  expect(await screen.findByText(/passt zu keiner importierten Schlüsselgeneration/)).toBeTruthy();
});

it('gesperrt: kein Eingabefeld, Hinweis zum Entsperren', () => {
  keyring.unlocked = false;
  render(LegacyKeyAdoption, { tenant: 't1' });
  expect(screen.queryByLabelText(/Alter privater Datenschlüssel/)).toBeNull();
  expect(screen.getByText(/Entsperren Sie zuerst/)).toBeTruthy();
});
