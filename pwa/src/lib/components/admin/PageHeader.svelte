<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';

  interface Props {
    title: string;
    /** Erklärtext unter dem Titel (14 px, gedämpft). */
    description?: string;
    /** Status badges next to the title. */
    badges?: Snippet;
    actions?: Snippet;
    /** Tab navigation (PageTabs) under the header, separated by a line. */
    tabs?: Snippet;
    /** Id of the heading; App.svelte moves focus to #page-title after navigation. */
    id?: string;
    /** One short primary action ("Kunde anlegen"): stays next to the title on phones instead of filling a row. */
    compactActions?: boolean;
    class?: string;
  }
  let {
    title,
    description,
    badges,
    actions,
    tabs,
    id = 'page-title',
    compactActions = false,
    class: className,
  }: Props = $props();
</script>

<!-- Grid instead of nested boxes: on phones the order is title, description, buttons, tabs; from
  sm: title and buttons share the first row, description and tabs span below. -->
<div
  class={cn(
    'grid gap-x-4 gap-y-3',
    compactActions
      ? 'grid-cols-[minmax(0,1fr)_auto]'
      : 'grid-cols-1 sm:grid-cols-[minmax(0,1fr)_auto]',
    className,
  )}
>
  <div
    class={cn(
      'min-w-0',
      compactActions ? 'col-start-1 row-start-1' : 'sm:col-start-1 sm:row-start-1',
    )}
  >
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
      <h1 {id} tabindex="-1" class="mb-0 min-w-0 break-words outline-none">{title}</h1>
      {#if badges}<div class="flex flex-wrap items-center gap-2">{@render badges()}</div>{/if}
    </div>
  </div>
  {#if description}<p
      class={cn(
        'ops-lead m-0 max-w-3xl',
        compactActions ? 'col-span-2 row-start-2' : 'max-sm:order-2 sm:col-span-2 sm:row-start-2',
      )}
    >
      {description}
    </p>{/if}
  {#if actions}<div
      class={cn(
        'flex items-start gap-2 sm:flex-wrap',
        compactActions
          ? 'col-start-2 row-start-1'
          : 'max-sm:order-3 max-sm:w-full sm:col-start-2 sm:row-start-1',
      )}
    >
      {@render actions()}
    </div>{/if}
  {#if tabs}<div
      class={cn(
        'min-w-0',
        compactActions ? 'col-span-2' : 'max-sm:order-4 sm:col-span-2',
        !compactActions && (description ? 'sm:row-start-3' : 'sm:row-start-2'),
      )}
    >
      {@render tabs()}
    </div>{/if}
</div>
