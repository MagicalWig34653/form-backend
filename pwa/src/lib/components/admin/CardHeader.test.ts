import { render, screen } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import CardHeader from './CardHeader.svelte';
import SaveStatus from './SaveStatus.svelte';
import { t } from '$lib/i18n';

it('setzt das Info-Symbol direkt hinter den Titel', () => {
  render(CardHeader, { title: 'Felder', hint: 'Wird im Entwurf gespeichert.' });
  const heading = screen.getByRole('heading', { name: 'Felder' });
  const info = screen.getByRole('img', { name: 'Wird im Entwurf gespeichert.' });
  expect(heading.parentElement).toBe(info.parentElement);
});
it('zeigt ohne Hinweis kein Info-Symbol', () => {
  render(CardHeader, { title: 'Felder' });
  expect(screen.queryByRole('img')).toBeNull();
});
it('nennt im Ruhezustand "Keine Änderungen"', () => {
  render(SaveStatus, { state: 'idle', idle: t.saveStatus.idle });
  expect(screen.getByRole('status').textContent).toContain('Keine Änderungen');
});
