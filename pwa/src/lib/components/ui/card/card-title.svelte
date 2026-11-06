<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';

  let { class: className, children, ...rest }: HTMLAttributes<HTMLHeadingElement> = $props();
</script>

<h1 class={cn('text-2xl leading-none font-semibold', className)} {...rest}>
  {@render children?.()}
</h1>
