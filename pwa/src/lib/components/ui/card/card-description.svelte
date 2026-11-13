<script lang="ts">
  import type { HTMLAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLAttributes<HTMLParagraphElement> = $props();
</script>

<p
  data-slot="card-description"
  class={cn('text-muted-foreground m-0 text-sm', className)}
  {...rest}
>
  {@render children?.()}
</p>
