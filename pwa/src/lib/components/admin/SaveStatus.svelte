<script lang="ts">
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import { formatClock } from '$lib/format';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  type State = 'idle' | 'dirty' | 'saving' | 'saved' | 'error';
  interface Props {
    state: State;
    /** Time of the last successful save ("Gespeichert · 23:55"). */
    at?: Date | null;
    /** Text for the idle state (nothing saved yet in this session). */
    idle?: string;
    /** Explanation behind the (i): how the card saves. */
    hint?: string;
    /** Error text shown instead of the generic one. */
    error?: string;
    /** The surrounding card already shows the error as an alert: no second live message. */
    quiet?: boolean;
    class?: string;
  }
  let {
    state,
    at = null,
    idle = '',
    hint,
    error = '',
    quiet = false,
    class: className,
  }: Props = $props();
  const ui = t.saveStatus;
  const label = $derived(
    state === 'saving'
      ? ui.saving
      : state === 'dirty'
        ? ui.dirty
        : state === 'error'
          ? error || ui.error
          : state === 'saved'
            ? at
              ? `${ui.saved} · ${formatClock(at)}`
              : ui.saved
            : idle,
  );
</script>

{#if label || hint}
  <span class={cn('flex min-w-0 items-center gap-1.5 text-sm', className)} data-slot="save-status">
    {#if label}
      <span
        role={quiet ? undefined : state === 'error' ? 'alert' : 'status'}
        data-state={state}
        class={cn(
          'inline-flex items-center gap-1.5',
          state === 'error'
            ? 'text-red-700 dark:text-destructive'
            : state === 'saved'
              ? 'text-emerald-700 dark:text-emerald-400'
              : state === 'dirty'
                ? 'text-amber-800 dark:text-amber-400'
                : 'text-muted-foreground',
        )}
      >
        {#if state === 'saved'}<NavIcon
            name="check"
            size={14}
          />{:else if state === 'error'}<NavIcon name="danger" size={14} />{/if}{label}
      </span>
    {/if}
    {#if hint}
      <span
        class="text-muted-foreground inline-flex size-6 items-center justify-center"
        title={hint}
        role="img"
        aria-label={hint}><NavIcon name="info" size={14} /></span
      >
    {/if}
  </span>
{/if}
