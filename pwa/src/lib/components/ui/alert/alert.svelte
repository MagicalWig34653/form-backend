<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLAttributes<HTMLDivElement> = $props();
</script>

<div
  data-slot="alert"
  role="alert"
  class={cn(
    'bg-card text-card-foreground relative w-full rounded-lg border px-3 py-2.5 text-sm',
    className,
  )}
  {...rest}
>
  {@render children?.()}
</div>
