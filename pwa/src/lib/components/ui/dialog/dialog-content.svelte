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
      'bg-popover text-popover-foreground ring-foreground/10 fixed z-50 flex max-h-[calc(100dvh-2rem)] flex-col gap-4 overflow-y-auto p-5 text-sm ring-1 outline-none',
      // Phones: docked to the bottom edge like a sheet; from sm up a centred dialog.
      'max-sm:inset-x-0 max-sm:bottom-0 max-sm:rounded-t-xl sm:top-1/2 sm:left-1/2 sm:w-[calc(100%-2rem)] sm:max-w-md sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-xl',
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
