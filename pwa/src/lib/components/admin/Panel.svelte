<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';
  import { Card } from '$lib/components/ui/card';

  interface Props {
    title?: string;
    description?: string;
    /** Heading level of the title (default 2). */
    level?: 2 | 3;
    actions?: Snippet;
    children?: Snippet;
    /** Remove the body padding, e.g. for tables that run edge to edge. */
    flush?: boolean;
    class?: string;
    id?: string;
  }
  let {
    title,
    description,
    level = 2,
    actions,
    children,
    flush = false,
    class: className,
    id,
  }: Props = $props();
  const heading = $derived(`h${level}`);
</script>

<Card
  {id}
  class={cn(
    'min-w-0 [--card-spacing:--spacing(5)] max-sm:[--card-spacing:--spacing(4)]',
    flush && !title && !actions && 'py-0',
    className,
  )}
>
  {#if title || actions}
    <header class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 px-(--card-spacing)">
      <div class="min-w-0">
        {#if title}<svelte:element
            this={heading}
            class="m-0 text-xl leading-snug font-semibold tracking-tight">{title}</svelte:element
          >{/if}
        {#if description}<p class="text-muted-foreground m-0 mt-0.5 text-sm leading-5">
            {description}
          </p>{/if}
      </div>
      {#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
    </header>
  {/if}
  <div class={cn(!flush && 'px-(--card-spacing)')}>
    {@render children?.()}
  </div>
</Card>
