import { render, screen } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import { expect, it } from 'vitest';
import PageHeader from './PageHeader.svelte';

const snippet = (text: string) =>
  createRawSnippet(() => ({ render: () => `<button>${text}</button>` }));

it('liest die Beschreibung direkt nach dem Titel und vor den Buttons', () => {
  render(PageHeader, { title: 'Kontakt', description: 'Kunde A', actions: snippet('Bearbeiten') });
  const title = screen.getByRole('heading', { name: 'Kontakt' });
  const description = screen.getByText('Kunde A');
  const button = screen.getByRole('button', { name: 'Bearbeiten' });
  const follows = (a: Node, b: Node) =>
    !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
  expect(follows(title, description)).toBe(true);
  expect(follows(description, button)).toBe(true);
});
