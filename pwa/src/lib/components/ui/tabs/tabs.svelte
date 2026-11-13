<script lang="ts">
  import { Tabs } from 'bits-ui';
  import type { ComponentProps } from 'svelte';
  import { cn } from '$lib/utils';
  let { class: className, children, ...rest }: ComponentProps<typeof Tabs.Root> = $props();
</script>

<Tabs.Root class={cn('flex flex-col gap-4', className)} {...rest}>{@render children?.()}</Tabs.Root>
