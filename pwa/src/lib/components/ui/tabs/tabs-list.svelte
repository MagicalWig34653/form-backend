<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.List> = $props();
</script>

<Tabs.List
  class={cn('bg-secondary inline-flex min-h-10 w-fit items-center gap-1 rounded-lg p-1', className)}
  {...rest}>{@render children?.()}</Tabs.List
>
