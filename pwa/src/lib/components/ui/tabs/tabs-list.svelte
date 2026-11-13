<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.List> = $props();
</script>

<Tabs.List
  data-slot="tabs-list"
  class={cn(
    'text-muted-foreground bg-muted inline-flex h-10 w-fit max-w-full items-center gap-1 overflow-x-auto rounded-lg p-[3px]',
    className,
  )}
  {...rest}>{@render children?.()}</Tabs.List
>
