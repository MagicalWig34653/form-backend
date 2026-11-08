<script lang="ts">
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    title: string;
    description?: string;
    /** Name of a NavIcon glyph. */
    icon?: string;
    /** Primary action (button or link). */
    action?: Snippet;
    class?: string;
  }
  let { title, description, icon = 'inbox', action, class: className }: Props = $props();
</script>

<div class={cn('flex flex-col items-center gap-2 px-6 py-10 text-center', className)}>
  <span
    aria-hidden="true"
    class="bg-muted text-muted-foreground mb-1 flex size-12 items-center justify-center rounded-full"
    ><NavIcon name={icon} size={22} /></span
  >
  <p class="m-0 text-[17px] leading-snug font-semibold">{title}</p>
  {#if description}<p class="text-muted-foreground m-0 max-w-md text-sm leading-5">
      {description}
    </p>{/if}
  {#if action}<div class="mt-2 flex flex-wrap justify-center gap-2">{@render action()}</div>{/if}
</div>
