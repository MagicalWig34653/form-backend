<script lang="ts">
  import { AlertDialog } from 'bits-ui';
  import type { ComponentProps, Snippet } from 'svelte';
  import { cn } from '$lib/utils';

  interface Props {
    title: string;
    description: string;
    class?: string;
    onOpenAutoFocus?: ComponentProps<typeof AlertDialog.Content>['onOpenAutoFocus'];
    /** Optional extra content between description and buttons (e.g. a typed confirmation). */
    body?: Snippet;
    /** Buttons: cancel on the left, primary action on the right. */
    children?: Snippet;
  }
  let { title, description, class: className, onOpenAutoFocus, body, children }: Props = $props();
</script>

<AlertDialog.Portal>
  <AlertDialog.Overlay class="fixed inset-0 z-50 bg-black/30" />
  <AlertDialog.Content
    data-slot="alert-dialog-content"
    {onOpenAutoFocus}
    class={cn(
      'bg-popover text-popover-foreground ring-foreground/10 fixed z-50 flex max-h-[calc(100dvh-2rem)] flex-col gap-4 overflow-y-auto p-5 text-sm shadow-lg ring-1 outline-none',
      'max-sm:inset-x-0 max-sm:bottom-0 max-sm:rounded-t-xl sm:top-1/2 sm:left-1/2 sm:w-[calc(100%-2rem)] sm:max-w-md sm:-translate-x-1/2 sm:-translate-y-1/2 sm:rounded-xl',
      className,
    )}
  >
    <div class="flex flex-col gap-1">
      <AlertDialog.Title class="text-lg leading-snug font-semibold">{title}</AlertDialog.Title>
      <AlertDialog.Description class="text-muted-foreground text-sm"
        >{description}</AlertDialog.Description
      >
    </div>
    {@render body?.()}
    <div
      class="flex flex-col-reverse flex-wrap items-stretch justify-end gap-2 sm:flex-row sm:items-center"
    >
      {@render children?.()}
    </div>
  </AlertDialog.Content>
</AlertDialog.Portal>
