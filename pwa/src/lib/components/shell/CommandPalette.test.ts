import { render, screen, fireEvent, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';

const { T, F, forms } = vi.hoisted(() => ({
  T: 'aaaaaaaa-1111-4111-8111-111111111111',
  F: 'bbbbbbbb-1111-4111-8111-111111111111',
  forms: vi.fn(),
}));
vi.mock('$lib/api', () => ({
  adminApi: { forms },
  http: { request: vi.fn().mockResolvedValue({ ok: true, data: { system: false, forms: [] } }) },
}));
vi.mock('$lib/session.svelte', () => ({
  session: {
    me: { id: 'u1', username: 'anna', systemAdministrator: false },
    tenants: [
      { id: T, name: 'Kunde A', permissions: [] },
      { id: 'cccccccc-1111-4111-8111-111111111111', name: 'Kunde B', permissions: [] },
    ],
    logout: vi.fn(),
  },
}));
vi.mock('$lib/theme.svelte', () => ({ theme: { toggle: vi.fn() } }));
import CommandPalette from './CommandPalette.svelte';
import { router } from '$lib/router.svelte';
import { shellState } from './shell-state.svelte';

beforeEach(() => {
  forms.mockResolvedValue({
    ok: true,
    data: {
      items: [{ id: F, name: 'Kontakt', active: true, currentReleaseId: null }],
      nextCursor: null,
    },
  });
  router.navigate(`/t/${T}`);
});
afterEach(() => {
  shellState.paletteOpen = false;
  vi.clearAllMocks();
});

it('opens with Ctrl+K, filters, navigates with arrows and Enter', async () => {
  const navigate = vi.spyOn(router, 'navigate');
  render(CommandPalette);
  expect(screen.queryByRole('dialog')).toBeNull();
  await fireEvent.keyDown(window, { key: 'k', ctrlKey: true });
  const input = await screen.findByRole('combobox', { name: 'Befehl oder Seite suchen' });
  expect(screen.getByRole('dialog')).toBeTruthy();
  await screen.findByRole('option', { name: /^Kontakt/ });
  await fireEvent.input(input, { target: { value: 'einsend kontakt' } });
  const options = screen.getAllByRole('option');
  expect(options).toHaveLength(1);
  expect(input.getAttribute('aria-activedescendant')).toBe(options[0]?.id);
  await fireEvent.keyDown(input, { key: 'Enter' });
  expect(navigate).toHaveBeenLastCalledWith(`/t/${T}/f/${F}/entries`);
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
});

it('hides the keyboard hint line on touch devices (coarse pointer)', async () => {
  render(CommandPalette);
  await fireEvent.keyDown(window, { key: 'k', ctrlKey: true });
  const hint = await screen.findByTestId('palette-keyhints');
  expect(hint.className).toContain('[@media(pointer:coarse)]:hidden');
});

it('arrow keys move the selection and wrap', async () => {
  render(CommandPalette);
  shellState.paletteOpen = true;
  const input = await screen.findByRole('combobox');
  const first = input.getAttribute('aria-activedescendant');
  await fireEvent.keyDown(input, { key: 'ArrowUp' });
  const last = input.getAttribute('aria-activedescendant');
  expect(last).not.toBe(first);
  await fireEvent.keyDown(input, { key: 'ArrowDown' });
  expect(input.getAttribute('aria-activedescendant')).toBe(first);
});

it('shows an empty message and Escape returns focus to the opener', async () => {
  const opener = document.createElement('button');
  document.body.append(opener);
  opener.focus();
  render(CommandPalette);
  shellState.paletteOpen = true;
  const input = await screen.findByRole('combobox');
  await fireEvent.input(input, { target: { value: 'zzzzzz' } });
  expect(screen.getByText('Keine Treffer.')).toBeTruthy();
  await fireEvent.keyDown(input, { key: 'Escape' });
  await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull());
  await waitFor(() => expect(document.activeElement).toBe(opener));
  opener.remove();
});
