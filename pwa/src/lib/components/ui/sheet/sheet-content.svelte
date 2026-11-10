<script lang="ts">
  import { Dialog } from 'bits-ui';
  import type { ComponentProps, Snippet } from 'svelte';
  import { cn } from '$lib/utils';

  interface Props {
    /** Accessible name of the sheet; shown as heading unless `hideHeader` is set. */
    title: string;
    description?: string;
    /** Edge the sheet slides in from. */
    side?: 'left' | 'right' | 'bottom';
    /** Keep title and description for assistive technology only (navigation sheets). */
    hideHeader?: boolean;
    class?: string;
    onOpenAutoFocus?: ComponentProps<typeof Dialog.Content>['onOpenAutoFocus'];
    children?: Snippet;
  }
  let {
    title,
    description,
    side = 'left',
    hideHeader = false,
    class: className,
    onOpenAutoFocus,
    children,
  }: Props = $props();

  const sides = {
    left: 'inset-y-0 left-0 h-dvh w-[88%] max-w-80 border-r',
    right: 'inset-y-0 right-0 h-dvh w-[88%] max-w-md border-l',
    bottom: 'inset-x-0 bottom-0 max-h-[85dvh] w-full rounded-t-xl border-t',
  } as const;
</script>

<Dialog.Portal>
  <Dialog.Overlay class="fixed inset-0 z-50 bg-black/30" />
  <Dialog.Content
    data-slot="sheet-content"
    data-side={side}
    {onOpenAutoFocus}
    class={cn(
      'bg-popover text-popover-foreground fixed z-50 flex flex-col overflow-y-auto shadow-lg outline-none',
      sides[side],
      className,
    )}
  >
    <div class={cn('flex flex-col gap-1 px-4 pt-4', hideHeader && 'sr-only')}>
      <Dialog.Title class="text-lg leading-snug font-semibold">{title}</Dialog.Title>
      <Dialog.Description class="text-muted-foreground text-sm"
        >{description ?? title}</Dialog.Description
      >
    </div>
    {@render children?.()}
  </Dialog.Content>
</Dialog.Portal>
