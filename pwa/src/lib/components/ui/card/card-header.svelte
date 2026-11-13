<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLAttributes<HTMLDivElement> = $props();
</script>

<div
  data-slot="card-header"
  class={cn(
    'flex flex-wrap items-start justify-between gap-x-4 gap-y-2 px-(--card-spacing)',
    className,
  )}
  {...rest}
>
  {@render children?.()}
</div>
