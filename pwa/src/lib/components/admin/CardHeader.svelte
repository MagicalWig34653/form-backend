<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

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
    /** Explanation behind an (i) right after the title, on every screen size. */
    hint?: string;
    actions?: Snippet;
    class?: string;
  }
  let { title, description, level = 2, id, hint, actions, class: className }: Props = $props();
  const heading = $derived(`h${level}`);
</script>

<header
  class={cn(
    'flex flex-wrap justify-between gap-x-4 gap-y-2',
    description ? 'items-start' : 'items-center',
    className,
  )}
  data-slot="card-header"
>
  <div class={cn('min-w-0 flex-1', description ? 'basis-72' : 'basis-40')}>
    {#if title}<div class="flex items-center gap-1">
        <svelte:element
          this={heading}
          {id}
          class="m-0 text-xl leading-snug font-semibold tracking-tight">{title}</svelte:element
        >{#if hint}<span
            class="text-muted-foreground inline-flex size-6 shrink-0 items-center justify-center"
            title={hint}
            role="img"
            aria-label={hint}><NavIcon name="info" size={14} /></span
          >{/if}
      </div>{/if}
    {#if description}<p class="text-muted-foreground m-0 mt-0.5 text-sm leading-5">
        {description}
      </p>{/if}
  </div>
  {#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</header>
