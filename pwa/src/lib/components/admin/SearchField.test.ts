import { fireEvent, render, screen } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import SearchField from './SearchField.svelte';

it('hat einen eigenen Namen, einen Platzhalter und übernimmt die Eingabe', async () => {
  render(SearchField, { id: 's', label: 'Formulare suchen', placeholder: 'Name …' });
  const field = screen.getByRole('searchbox', { name: 'Formulare suchen' }) as HTMLInputElement;
  expect(field.placeholder).toBe('Name …');
  await fireEvent.input(field, { target: { value: 'kontakt' } });
  expect(field.value).toBe('kontakt');
});
