<script lang="ts">
  import { Dialog } from 'bits-ui';
  import type { Snippet } from 'svelte';
  import { cn } from '$lib/utils';

  interface Props {
    title: string;
    description: string;
    class?: string;
    children?: Snippet;
  }
  let { title, description, class: className, children }: Props = $props();
</script>

<Dialog.Portal>
  <Dialog.Overlay class="fixed inset-0 z-50 bg-black/10 backdrop-blur-xs" />
  <Dialog.Content
    data-slot="dialog-content"
    class={cn(
      'bg-popover text-popover-foreground ring-foreground/10 fixed top-1/2 left-1/2 z-50 flex max-h-[calc(100dvh-2rem)] w-[calc(100%-2rem)] max-w-md -translate-x-1/2 -translate-y-1/2 flex-col gap-4 overflow-y-auto rounded-xl p-5 text-sm ring-1 outline-none',
      className,
    )}
  >
    <div class="flex flex-col gap-1">
      <Dialog.Title class="text-lg leading-snug font-semibold">{title}</Dialog.Title>
      <Dialog.Description class="text-muted-foreground text-sm">{description}</Dialog.Description>
    </div>
    <div class="flex flex-wrap items-center justify-end gap-2">
      {@render children?.()}
    </div>
  </Dialog.Content>
</Dialog.Portal>
