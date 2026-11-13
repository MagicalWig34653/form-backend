import { render, screen } from '@testing-library/svelte';
import { expect, it } from 'vitest';
import { createRawSnippet } from 'svelte';
import DataTable from './DataTable.svelte';

type Row = { id: string; name: string; rights: string };
const cell = createRawSnippet<[Row, { id: string }]>((row, column) => ({
  render: () => `<span>${column().id === 'name' ? row().name : row().rights}</span>`,
}));

it('stacks a column hidden on narrow screens under the first cell and names it for screen readers', () => {
  const { container } = render(DataTable<Row>, {
    label: 'Kunden',
    columns: [
      { id: 'name', header: 'Name' },
      { id: 'rights', header: 'Ihre Rechte', hideBelow: 'sm' },
    ],
    rows: [{ id: '1', name: 'Kunde A', rights: 'Lesen' }],
    rowKey: (r: Row) => r.id,
    cell,
  });
  const stacked = container.querySelector('tbody th [data-extras]')!;
  expect(stacked.textContent).toContain('Ihre Rechte:');
  expect(stacked.textContent).toContain('Lesen');
  expect(stacked.querySelector('.sr-only')).toBeTruthy();
  expect(screen.getByRole('columnheader', { name: 'Ihre Rechte' }).className).toContain(
    'max-sm:hidden',
  );
});
