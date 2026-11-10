<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';
  import { Card } from '$lib/components/ui/card';
  import CardHeader from './CardHeader.svelte';

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
    <CardHeader {title} {description} {level} {actions} class="px-(--card-spacing)" />
  {/if}
  <div class={cn(!flush && 'px-(--card-spacing)')}>
    {@render children?.()}
  </div>
</Card>
