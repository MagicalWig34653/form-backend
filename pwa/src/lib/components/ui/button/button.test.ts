import { render, screen } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import { createRawSnippet } from 'svelte';
import Button from './button.svelte';

const label = createRawSnippet(() => ({ render: () => '<span>Weiter</span>' }));

it('deaktivierter Primärbutton behält einen sichtbaren Rahmen (Dunkelmodus)', () => {
  render(Button, { disabled: true, children: label });
  expect(screen.getByRole('button').className).toContain('disabled:border-border');
});
