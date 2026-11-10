<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';

  /**
   * The one header of every card and section: title, optional one-line description and actions
   * with a fixed 2 px gap between title and description, so that no card looks different.
   */
  interface Props {
    title?: string;
    description?: string;
    /** Heading level of the title (default 2). */
    level?: 2 | 3;
    id?: string;
    actions?: Snippet;
    class?: string;
  }
  let { title, description, level = 2, id, actions, class: className }: Props = $props();
  const heading = $derived(`h${level}`);
</script>

<header
  class={cn('flex flex-wrap items-start justify-between gap-x-4 gap-y-2', className)}
  data-slot="card-header"
>
  <div class="min-w-0">
    {#if title}<svelte:element
        this={heading}
        {id}
        class="m-0 text-xl leading-snug font-semibold tracking-tight">{title}</svelte:element
      >{/if}
    {#if description}<p class="text-muted-foreground m-0 mt-0.5 text-sm leading-5">
        {description}
      </p>{/if}
  </div>
  {#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</header>
