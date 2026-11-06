<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.Trigger> = $props();
</script>

<Tabs.Trigger
  class={cn(
    'text-muted-foreground rounded-md px-3 py-2 text-sm font-medium data-[state=active]:bg-background data-[state=active]:text-foreground data-[state=active]:shadow-sm disabled:opacity-50',
    className,
  )}
  {...rest}>{@render children?.()}</Tabs.Trigger
>
