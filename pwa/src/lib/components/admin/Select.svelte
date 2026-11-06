<script lang="ts">
  import type { HTMLSelectAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { value = $bindable(), class: className, children, ...rest }: HTMLSelectAttributes = $props();
</script>

<select
  bind:value
  class={cn(
    'border-input bg-background flex min-h-10 w-full min-w-0 rounded-md border px-3 py-2 text-sm shadow-xs disabled:opacity-50',
    className,
  )}
  {...rest}
>
  {@render children?.()}
</select>
