<script lang="ts">
  import type { Snippet } from 'svelte';
  import Panel from './Panel.svelte';

  interface Props {
    title?: string;
    description?: string;
    /** Space-separated delay index for the staggered fade-in. */
    index?: number;
    level?: 2 | 3;
    id?: string;
    actions?: Snippet;
    /** Buttons row at the bottom, separated from the fields. */
    footer?: Snippet;
    children?: Snippet;
    class?: string;
  }
  let {
    title,
    description,
    index = 0,
    level = 2,
    id,
    actions,
    footer,
    children,
    class: className,
  }: Props = $props();
</script>

<Panel {title} {description} {level} {id} {actions} class={className}>
  <div style:--i={index} class="grid gap-5">
    {@render children?.()}
  </div>
  {#if footer}
    <div class="border-subtle mt-5 flex flex-wrap items-center gap-2 border-t pt-4">
      {@render footer()}
    </div>
  {/if}
</Panel>
