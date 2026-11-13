<script lang="ts">
  import { tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { confirmState } from '$lib/confirm.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import {
    AlertDialog,
    AlertDialogCancel,
    AlertDialogContent,
  } from '$lib/components/ui/alert-dialog';

  const current = $derived(confirmState.current);
  let typed = $state('');
  const ready = $derived(!current?.requireText || typed.trim() === current.requireText);
  $effect(() => {
    if (current) typed = '';
  });

  // Destructive questions start on "Abbrechen"; the others on the primary button.
  async function focusStart(event: Event): Promise<void> {
    event.preventDefault();
    await tick();
    const selector = current?.requireText
      ? '#confirm-name'
      : current?.destructive
        ? '[data-confirm-cancel]'
        : '[data-confirm-action]';
    document.querySelector<HTMLElement>(selector)?.focus();
  }
</script>

<AlertDialog
  open={current !== null}
  onOpenChange={(open) => {
    if (!open) confirmState.settle(false);
  }}
>
  {#if current}
    <AlertDialogContent
      title={current.title}
      description={current.description}
      onOpenAutoFocus={focusStart}
    >
      {#snippet body()}
        {#if current.requireText}
          <div class="flex flex-col gap-1.5">
            <label for="confirm-name" class="text-sm font-medium"
              >{t.confirm.typeToConfirm.replace('{name}', current.requireText ?? '')}</label
            >
            <Input id="confirm-name" bind:value={typed} autocomplete="off" spellcheck={false} />
          </div>
        {/if}
      {/snippet}
      <AlertDialogCancel
        >{#snippet child({ props })}<Button {...props} variant="ghost" data-confirm-cancel
            >{current.cancelLabel ?? t.confirm.cancel}</Button
          >{/snippet}</AlertDialogCancel
      >
      <Button
        type="button"
        variant={current.destructive ? 'destructive' : 'default'}
        data-confirm-action
        disabled={!ready}
        onclick={() => confirmState.settle(true)}>{current.confirmLabel}</Button
      >
    </AlertDialogContent>
  {/if}
</AlertDialog>
