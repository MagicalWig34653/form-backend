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
  bind:checked
  class={cn('size-5 shrink-0 accent-[var(--ui-accent)] disabled:opacity-50', className)}
  {...rest}
/>
