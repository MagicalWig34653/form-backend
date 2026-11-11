<script lang="ts">
  import { tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { stepUp as defaultStepUp } from '$lib/admin/guard.svelte';
  import type { StepUp } from '$lib/admin/stepup.svelte';
  import { Button } from '$lib/components/ui/button';
  import {
    AlertDialog,
    AlertDialogCancel,
    AlertDialogContent,
  } from '$lib/components/ui/alert-dialog';

  /** The passkey step-up dialog on the current page (ADR 0037); rendered once, like ConfirmHost. */
  let { controller = defaultStepUp }: { controller?: StepUp } = $props();

  const r = t.reauth;
  const working = $derived(controller.phase === 'working');
  const message = $derived(
    controller.error === 'cancelled'
      ? r.cancelled
      : controller.error === 'rateLimited'
        ? r.rateLimited
        : controller.error === 'failed'
          ? r.failed
          : '',
  );

  async function focusStart(event: Event): Promise<void> {
    event.preventDefault();
    await tick();
    document.querySelector<HTMLElement>('[data-reauth-action]')?.focus();
  }
</script>

<AlertDialog
  open={controller.open}
  onOpenChange={(open) => {
    if (!open) controller.cancel();
  }}
>
  {#if controller.open}
    <AlertDialogContent title={r.title} description={r.description} onOpenAutoFocus={focusStart}>
      {#snippet body()}
        <div aria-live="polite" class="min-h-0 text-sm">
          {#if working}
            <p role="status" class="text-muted-foreground">{r.working}</p>
          {:else if message}
            <p role="alert" class="text-destructive">{message}</p>
          {/if}
        </div>
      {/snippet}
      <AlertDialogCancel
        >{#snippet child({ props })}<Button {...props} variant="ghost" data-reauth-cancel
            >{r.cancel}</Button
          >{/snippet}</AlertDialogCancel
      >
      <Button
        type="button"
        data-reauth-action
        aria-disabled={working}
        aria-busy={working}
        onclick={() => void controller.confirm()}
        >{controller.phase === 'error' ? r.retry : r.confirm}</Button
      >
    </AlertDialogContent>
  {/if}
</AlertDialog>
