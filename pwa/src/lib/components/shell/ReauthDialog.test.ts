import { render, screen, fireEvent, waitFor, within } from '@testing-library/svelte';
import { expect, it, vi } from 'vitest';
import ReauthDialog from './ReauthDialog.svelte';
import { createStepUp } from '$lib/admin/stepup.svelte';
import type { PasskeyOutcome } from '$lib/api/webauthn';

function controller(assertion: () => Promise<PasskeyOutcome>) {
  return createStepUp({
    options: async () => ({
      ok: true,
      data: {
        challengeId: 'c1',
        publicKey: {
          challenge: 'AAAA',
          rpId: 'localhost',
          timeout: 1,
          userVerification: 'required',
          allowCredentials: [],
        },
        expiresAt: 'x',
      },
    }),
    verify: async () => ({ ok: true, data: {} }),
    assertion,
    supported: () => true,
    onUserAction: () => () => {},
  });
}
const ok: PasskeyOutcome = {
  ok: true,
  body: {
    challengeId: 'c1',
    credential: {
      id: 'AQ',
      rawId: 'AQ',
      type: 'public-key',
      response: { authenticatorData: 'AQ', clientDataJSON: 'AQ', signature: 'AQ' },
    },
  },
};

it('fragt den Passkey im Dialog ab, fokussiert die Bestätigung und schließt nach Erfolg', async () => {
  const c = controller(async () => ok);
  render(ReauthDialog, { controller: c });
  const result = c.request();
  const dialog = await screen.findByRole('alertdialog', { name: 'Bestätigung erforderlich' });
  const button = within(dialog).getByRole('button', { name: 'Mit Passkey bestätigen' });
  await waitFor(() => expect(document.activeElement).toBe(button));
  await fireEvent.click(button);
  expect(await result).toBe('confirmed');
  await waitFor(() => expect(screen.queryByRole('alertdialog')).toBeNull());
});

it('zeigt nach abgebrochener Abfrage eine Meldung mit „Erneut versuchen“; Escape bricht ab', async () => {
  const assertion = vi.fn(async (): Promise<PasskeyOutcome> => ({
    ok: false,
    reason: 'cancelled',
  }));
  const c = controller(assertion);
  render(ReauthDialog, { controller: c });
  const result = c.request();
  const dialog = await screen.findByRole('alertdialog');
  await fireEvent.click(within(dialog).getByRole('button', { name: 'Mit Passkey bestätigen' }));
  expect((await within(dialog).findByRole('alert')).textContent).toMatch(/abgebrochen/);
  expect(within(dialog).getByRole('button', { name: 'Erneut versuchen' })).toBeTruthy();
  await fireEvent.keyDown(dialog, { key: 'Escape' });
  expect(await result).toBe('cancelled');
});

it('„Abbrechen“ schließt den Dialog', async () => {
  const c = controller(async () => ok);
  render(ReauthDialog, { controller: c });
  const result = c.request();
  const dialog = await screen.findByRole('alertdialog');
  await fireEvent.click(within(dialog).getByRole('button', { name: 'Abbrechen' }));
  expect(await result).toBe('cancelled');
});
