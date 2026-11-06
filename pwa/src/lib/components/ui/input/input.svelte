<script lang="ts">
  import type { HTMLInputAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { value = $bindable(), class: className, ...rest }: HTMLInputAttributes = $props();
</script>

<input
  bind:value
  class={cn(
    'border-input bg-background placeholder:text-muted-foreground flex min-h-10 w-full min-w-0 rounded-md border px-3 py-2 text-sm shadow-xs disabled:opacity-50',
    className,
  )}
  {...rest}
/>
