<script lang="ts" module>
  export interface Column {
    id: string;
    header: string;
    align?: 'left' | 'right';
    /** Hide the column below this breakpoint; keep the first column and the actions visible. */
    hideBelow?: 'sm' | 'md';
    /** Visually hide the header text (action columns); it stays available to screen readers. */
    srOnlyHeader?: boolean;
    class?: string;
  }
</script>

<script lang="ts" generics="T">
  import type { Snippet } from 'svelte';
  import { Table } from '$lib/components/ui/table';
  import { cn } from '$lib/utils';

  interface Props {
    /** Name of the table (caption) and of its scroll region. */
    label: string;
    columns: Column[];
    rows: T[];
    rowKey: (row: T) => string;
    /** Cell content; the first column is rendered as the row header. */
    cell: Snippet<[T, Column]>;
    class?: string;
  }
  let { label, columns, rows, rowKey, cell, class: className }: Props = $props();

  const hide = (column: Column): string =>
    column.hideBelow === 'sm' ? 'max-sm:hidden' : column.hideBelow === 'md' ? 'max-md:hidden' : '';
</script>

<Table {label} class={cn('text-[length:var(--fs-body)]', className)}>
  <caption class="sr-only">{label}</caption>
  <thead class="bg-surface-sunken text-muted-foreground text-[length:var(--fs-small)]">
    <tr>
      {#each columns as column (column.id)}
        <th
          scope="col"
          class={cn(
            'h-10 !py-0 whitespace-nowrap',
            column.align === 'right' ? 'text-right' : 'text-left',
            hide(column),
            column.class,
          )}><span class={cn(column.srOnlyHeader && 'sr-only')}>{column.header}</span></th
        >
      {/each}
    </tr>
  </thead>
  <tbody>
    {#each rows as row (rowKey(row))}
      <tr class="hover:bg-surface-sunken/60 h-11 transition-colors">
        {#each columns as column, index (column.id)}
          {#if index === 0}
            <th scope="row" class={cn('!py-1.5 text-left font-medium', hide(column), column.class)}
              >{@render cell(row, column)}</th
            >
          {:else}
            <td
              class={cn(
                '!py-1.5',
                column.align === 'right' && 'text-right',
                hide(column),
                column.class,
              )}>{@render cell(row, column)}</td
            >
          {/if}
        {/each}
      </tr>
    {/each}
  </tbody>
</Table>
