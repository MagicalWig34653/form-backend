import { render, screen } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import SaveStatus from './SaveStatus.svelte';

const at = new Date(2026, 10, 3, 23, 55);

it('zeigt Gespeichert mit Uhrzeit', () => {
  render(SaveStatus, { state: 'saved', at });
  expect(screen.getByRole('status').textContent).toContain('Gespeichert · 23:55');
});
it('zeigt Speichern, ungespeicherte Änderungen und Fehler', () => {
  const { rerender } = render(SaveStatus, { state: 'saving' });
  expect(screen.getByRole('status').textContent).toContain('Speichert …');
  void rerender({ state: 'dirty' });
});
it('meldet Fehler als Hinweis mit eigenem Text', () => {
  render(SaveStatus, { state: 'error', error: 'Der Entwurf wurde geändert.' });
  expect(screen.getByRole('alert').textContent).toContain('Der Entwurf wurde geändert.');
});
it('unterdrückt die Live-Meldung, wenn die Karte den Fehler selbst meldet', () => {
  render(SaveStatus, { state: 'error', quiet: true });
  expect(screen.queryByRole('alert')).toBeNull();
  expect(screen.getByText('Speichern fehlgeschlagen')).toBeTruthy();
});
it('zeigt im Ruhezustand nur die Erklärung als Info-Symbol', () => {
  render(SaveStatus, { state: 'idle', hint: 'Wird im Entwurf gespeichert.' });
  expect(screen.queryByRole('status')).toBeNull();
  expect(screen.getByRole('img', { name: 'Wird im Entwurf gespeichert.' })).toBeTruthy();
});
