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
  import { router } from '$lib/router.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { cn } from '$lib/utils';

  interface Props {
    /** Name of the table (caption) and of its scroll region. */
    label: string;
    columns: Column[];
    rows: T[];
    rowKey: (row: T) => string;
    /** Cell content; the first column is rendered as the row header. */
    cell: Snippet<[T, Column]>;
    /** Target of a row: the whole row is then clickable and ends with a chevron. */
    rowHref?: (row: T) => string;
    class?: string;
  }
  let { label, columns, rows, rowKey, cell, rowHref, class: className }: Props = $props();

  // Below the breakpoint a hidden column is not lost: it moves under the first cell as a second line.
  const hiddenColumns = $derived(columns.filter((c, i) => i > 0 && c.hideBelow));
  function openRow(event: MouseEvent, row: T): void {
    if (!rowHref || event.defaultPrevented) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if ((event.target as HTMLElement).closest('a,button,input,select,textarea,label')) return;
    router.navigate(rowHref(row));
  }

  const hide = (column: Column): string =>
    column.hideBelow === 'sm' ? 'max-sm:hidden' : column.hideBelow === 'md' ? 'max-md:hidden' : '';
</script>

<Table {label} class={className}>
  <caption class="sr-only">{label}</caption>
  <thead class="bg-muted/50 text-muted-foreground text-sm">
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
      {#if rowHref}<th scope="col" class="w-10 !py-0"><span class="sr-only">{label}</span></th>{/if}
    </tr>
  </thead>
  <tbody>
    {#each rows as row (rowKey(row))}
      <tr
        class={cn('hover:bg-muted/50 h-12 transition-colors', rowHref && 'cursor-pointer')}
        onclick={(e) => openRow(e, row)}
      >
        {#each columns as column, index (column.id)}
          {#if index === 0}
            <th scope="row" class={cn('!py-1.5 text-left font-medium', hide(column), column.class)}
              >{@render cell(row, column)}{#each hiddenColumns as extra (extra.id)}<div
                  class="text-muted-foreground mt-0.5 text-xs font-normal sm:hidden"
                >
                  {@render cell(row, extra)}
                </div>{/each}</th
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
        {#if rowHref}<td class="w-10 !py-1.5 text-right" aria-hidden="true"
            ><span class="text-muted-foreground inline-flex"
              ><NavIcon name="chevron" size={16} /></span
            ></td
          >{/if}
      </tr>
    {/each}
  </tbody>
</Table>
