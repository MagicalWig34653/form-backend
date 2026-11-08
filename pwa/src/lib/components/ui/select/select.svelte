<script lang="ts">
  import type { HTMLSelectAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let {
    value = $bindable(''),
    class: className,
    children,
    ...rest
  }: HTMLSelectAttributes = $props();
</script>

<select
  bind:value
  class={cn(
    'select-ctl border-input bg-background min-h-10 w-full min-w-0 rounded-[var(--r-ctl)] border py-2 pr-9 pl-3 text-sm shadow-xs disabled:opacity-50',
    className,
  )}
  {...rest}>{@render children?.()}</select
>
