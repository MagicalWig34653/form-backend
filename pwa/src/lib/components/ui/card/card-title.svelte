<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLAttributes<HTMLHeadingElement> = $props();
</script>

<h3
  data-slot="card-title"
  class={cn('text-xl leading-snug font-semibold tracking-tight', className)}
  {...rest}
>
  {@render children?.()}
</h3>
