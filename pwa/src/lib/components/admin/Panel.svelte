<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';

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

<section {id} class={cn('surface-card min-w-0', className)}>
  {#if title || actions}
    <header class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2 px-5 pt-4 pb-1">
      <div class="min-w-0">
        {#if title}<svelte:element
            this={heading}
            class="text-[length:var(--fs-h2)] leading-[26px] font-semibold tracking-tight"
            >{title}</svelte:element
          >{/if}
        {#if description}<p
            class="text-muted-foreground text-[length:var(--fs-small)] leading-[18px]"
          >
            {description}
          </p>{/if}
      </div>
      {#if actions}<div class="flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
    </header>
  {/if}
  <div class={cn(flush ? '' : 'px-5 py-4', !title && !actions && !flush && 'pt-5')}>
    {@render children?.()}
  </div>
</section>
