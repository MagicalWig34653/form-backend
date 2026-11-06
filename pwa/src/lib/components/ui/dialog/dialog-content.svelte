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
  <Dialog.Overlay class="fixed inset-0 z-50 bg-black/60" />
  <Dialog.Content
    class={cn(
      'bg-card border-border fixed top-1/2 left-1/2 z-50 w-[calc(100%-2rem)] max-w-md -translate-x-1/2 -translate-y-1/2 rounded-xl border p-6 shadow-lg',
      className,
    )}
  >
    <Dialog.Title class="text-lg font-semibold">{title}</Dialog.Title>
    <Dialog.Description class="text-muted-foreground mt-2 text-sm">
      {description}
    </Dialog.Description>
    <div class="mt-4 flex flex-wrap items-center justify-end gap-3">
      {@render children?.()}
    </div>
  </Dialog.Content>
</Dialog.Portal>
