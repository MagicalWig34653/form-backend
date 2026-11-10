<script lang="ts">
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import { Button } from '$lib/components/ui/button';

  interface Props {
    /** The bar is shown only while there are unsaved changes (or a status to report). */
    dirty: boolean;
    busy?: boolean;
    /** Id of the form the save button submits; alternatively pass onsave. */
    form?: string;
    onsave?: () => void;
    ondiscard?: () => void;
    /** Short status after saving ("Gespeichert") or an error; shown instead of the hint. */
    status?: string;
    statusKind?: 'ok' | 'error';
    saveLabel?: string;
    class?: string;
  }
  let {
    dirty,
    busy = false,
    form,
    onsave,
    ondiscard,
    status = '',
    statusKind = 'ok',
    saveLabel = t.saveBar.save,
    class: className,
  }: Props = $props();
  /** A success message describes the saved state; once the user edits again it must not linger. */
  const message = $derived(status && !(dirty && statusKind === 'ok') ? status : t.saveBar.unsaved);
</script>

{#if dirty || status}
  <div
    role="region"
    aria-label={t.saveBar.label}
    class={cn(
      'bg-background/95 sticky bottom-4 z-10 flex flex-wrap items-center gap-x-4 gap-y-2 rounded-xl border px-4 py-3 shadow-lg backdrop-blur',
      className,
    )}
  >
    <p
      class={cn(
        'm-0 min-w-0 flex-1 basis-48 text-sm',
        status && statusKind === 'error'
          ? 'text-red-700 dark:text-destructive'
          : 'text-muted-foreground',
      )}
      role={message === status ? (statusKind === 'error' ? 'alert' : 'status') : undefined}
    >
      {message}
    </p>
    {#if dirty}
      <div class="flex items-center gap-2">
        {#if ondiscard}
          <Button type="button" variant="ghost" disabled={busy} onclick={ondiscard}
            >{t.saveBar.discard}</Button
          >
        {/if}
        <Button type={onsave ? 'button' : 'submit'} {form} disabled={busy} onclick={onsave}
          >{saveLabel}</Button
        >
      </div>
    {/if}
  </div>
{/if}
