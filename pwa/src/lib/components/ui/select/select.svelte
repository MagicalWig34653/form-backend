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
  data-slot="select"
  bind:value
  class={cn(
    'select-ctl border-input dark:bg-input/30 focus-visible:border-ring focus-visible:ring-ring/50 h-10 w-full min-w-0 rounded-lg border bg-transparent py-1 pr-9 pl-3 text-sm transition-colors outline-none focus-visible:ring-3 disabled:cursor-not-allowed disabled:opacity-50',
    className,
  )}
  {...rest}>{@render children?.()}</select
>
