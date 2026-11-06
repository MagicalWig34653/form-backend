<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.Content> = $props();
</script>

<Tabs.Content class={cn('outline-none', className)} {...rest}>{@render children?.()}</Tabs.Content>
