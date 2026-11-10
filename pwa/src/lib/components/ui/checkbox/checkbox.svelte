<script lang="ts">
  import type { HTMLInputAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let {
    checked = $bindable(),
    class: className,
    ...rest
  }: Omit<HTMLInputAttributes, 'type'> = $props();
</script>

<input
  type="checkbox"
  data-slot="checkbox"
  bind:checked
  class={cn(
    'border-control bg-background checked:bg-primary checked:border-primary focus-visible:border-ring focus-visible:ring-ring/50 relative size-5 shrink-0 appearance-none rounded-[5px] border transition-colors outline-none focus-visible:ring-3 disabled:cursor-not-allowed disabled:opacity-60 disabled:not-checked:bg-muted',
    "checked:after:border-primary-foreground checked:after:absolute checked:after:top-[1px] checked:after:left-[5.5px] checked:after:h-[11px] checked:after:w-[6px] checked:after:rotate-45 checked:after:border-r-2 checked:after:border-b-2 checked:after:content-['']",
    className,
  )}
  {...rest}
/>
