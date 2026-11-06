<script lang="ts">
  import type { HTMLInputAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let {
    checked = $bindable(false),
    class: className,
    ...rest
  }: Omit<HTMLInputAttributes, 'type'> = $props();
</script>

<input
  type="checkbox"
  role="switch"
  bind:checked
  class={cn(
    'h-6 w-11 shrink-0 appearance-none rounded-full border border-input bg-secondary transition-colors before:mt-0.5 before:ml-0.5 before:block before:size-4 before:rounded-full before:bg-foreground before:transition-transform checked:bg-ui-accent checked:before:translate-x-5 checked:before:bg-white disabled:opacity-50',
    className,
  )}
  {...rest}
/>
