<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.Trigger> = $props();
</script>

<Tabs.Trigger
  data-slot="tabs-trigger"
  class={cn(
    'text-foreground/70 hover:text-foreground focus-visible:ring-ring/50 data-[state=active]:bg-background data-[state=active]:text-foreground dark:data-[state=active]:bg-input/30 inline-flex h-full flex-1 items-center justify-center rounded-md border border-transparent px-3 text-sm font-medium whitespace-nowrap transition-all outline-none focus-visible:ring-3 data-[state=active]:shadow-sm disabled:pointer-events-none disabled:opacity-50',
    className,
  )}
  {...rest}>{@render children?.()}</Tabs.Trigger
>
