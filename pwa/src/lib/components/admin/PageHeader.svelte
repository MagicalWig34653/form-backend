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

<div class={cn('flex flex-col gap-4', className)}>
  <header class="flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
    <div class={cn('min-w-0 flex-1', compactActions ? 'basis-40' : 'basis-64')}>
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h1 {id} tabindex="-1" class="mb-0 min-w-0 break-words outline-none">{title}</h1>
        {#if badges}<div class="flex flex-wrap items-center gap-2">{@render badges()}</div>{/if}
      </div>
      {#if description}<p class="ops-lead mt-2 mb-0 max-w-3xl">{description}</p>{/if}
    </div>
    {#if actions}<div
        class={cn('flex items-center gap-2 sm:flex-wrap', !compactActions && 'max-sm:w-full')}
      >
        {@render actions()}
      </div>{/if}
  </header>
  {@render tabs?.()}
</div>
