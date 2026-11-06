<script lang="ts">
  import type { HTMLInputAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { value = $bindable(), class: className, ...rest }: HTMLInputAttributes = $props();
</script>

<input
  bind:value
  class={cn(
    'border-border bg-background placeholder:text-muted-foreground flex min-h-10 w-full rounded-md border px-3 py-2 text-sm disabled:opacity-50',
    className,
  )}
  {...rest}
/>
