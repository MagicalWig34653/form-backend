<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { class: className, children, ...rest }: HTMLAttributes<HTMLDivElement> = $props();
</script>

<div class={cn('bg-card border-border rounded-xl border p-6 shadow-sm', className)} {...rest}>
  {@render children?.()}
</div>
