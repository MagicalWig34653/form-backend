<script lang="ts">
  import type { HTMLTextareaAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { value = $bindable(''), class: className, ...rest }: HTMLTextareaAttributes = $props();
</script>

<textarea
  bind:value
  class={cn(
    'border-input bg-background min-h-10 w-full rounded-md border px-3 py-2 text-sm disabled:opacity-50',
    className,
  )}
  {...rest}></textarea>
