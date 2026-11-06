<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLAttributes<HTMLSpanElement> = $props();
</script>

<span
  class={cn(
    'inline-flex items-center rounded-full border border-border bg-secondary px-2.5 py-0.5 text-xs font-medium',
    className,
  )}
  {...rest}>{@render children?.()}</span
>
