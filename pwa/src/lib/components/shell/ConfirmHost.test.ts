import { render, screen, fireEvent, waitFor, within } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import ConfirmHost from './ConfirmHost.svelte';
import { confirmAction } from '$lib/confirm.svelte';

const base = { title: 'Konto sperren', description: 'Folgen.', confirmLabel: 'Sperren' };

it('resolves true only on the primary button and false on cancel or Escape', async () => {
  render(ConfirmHost);
  const yes = confirmAction(base);
  const dialog = await screen.findByRole('alertdialog', { name: 'Konto sperren' });
  await fireEvent.click(within(dialog).getByRole('button', { name: 'Sperren' }));
  expect(await yes).toBe(true);
  await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());

  const no = confirmAction(base);
  const second = await screen.findByRole('alertdialog');
  await fireEvent.click(within(second).getByRole('button', { name: 'Abbrechen' }));
  expect(await no).toBe(false);
  await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());

  const esc = confirmAction(base);
  const third = await screen.findByRole('alertdialog');
  await fireEvent.keyDown(third, { key: 'Escape' });
  expect(await esc).toBe(false);
});

it('keeps the primary button disabled until the name is typed', async () => {
  render(ConfirmHost);
  const answer = confirmAction({
    ...base,
    title: 'Kunde löschen',
    confirmLabel: 'Löschen',
    destructive: true,
    requireText: 'Muster GmbH',
  });
  const dialog = await screen.findByRole('alertdialog', { name: 'Kunde löschen' });
  const button = within(dialog).getByRole('button', { name: 'Löschen' }) as HTMLButtonElement;
  expect(button.disabled).toBe(true);
  await fireEvent.input(within(dialog).getByLabelText(/Muster GmbH/), {
    target: { value: 'Muster GmbH' },
  });
  expect(button.disabled).toBe(false);
  await fireEvent.click(button);
  expect(await answer).toBe(true);
});
