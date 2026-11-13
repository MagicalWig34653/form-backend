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
  data-slot="switch"
  data-state={checked ? 'checked' : 'unchecked'}
  bind:checked
  class={cn(
    'bg-control checked:bg-primary focus-visible:ring-ring/50 h-[22px] w-10 shrink-0 appearance-none rounded-full border border-transparent transition-colors outline-none focus-visible:ring-3 disabled:cursor-not-allowed disabled:opacity-60',
    'before:bg-background before:mt-px before:ml-px before:block before:size-[18px] before:rounded-full before:transition-transform before:content-[""] checked:before:translate-x-[18px] checked:before:bg-primary-foreground dark:before:bg-foreground',
    className,
  )}
  {...rest}
/>
