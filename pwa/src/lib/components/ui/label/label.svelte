<script lang="ts">
  import type { HTMLLabelAttributes } from 'svelte/elements';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: HTMLLabelAttributes = $props();
</script>

<label
  data-slot="label"
  class={cn('text-sm leading-none font-medium select-none', className)}
  {...rest}>{@render children?.()}</label
>
