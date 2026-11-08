<script lang="ts">
  import type { HTMLInputAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { value = $bindable(), class: className, ...rest }: HTMLInputAttributes = $props();
</script>

<input
  data-slot="input"
  bind:value
  class={cn(
    'border-input dark:bg-input/30 focus-visible:border-ring focus-visible:ring-ring/50 aria-invalid:ring-destructive/20 aria-invalid:border-destructive placeholder:text-muted-foreground flex h-10 w-full min-w-0 rounded-lg border bg-transparent px-3 py-1 text-sm transition-colors outline-none focus-visible:ring-3 aria-invalid:ring-3 disabled:cursor-not-allowed disabled:opacity-50',
    className,
  )}
  {...rest}
/>
