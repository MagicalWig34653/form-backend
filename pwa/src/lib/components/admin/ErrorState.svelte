<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { Button } from '$lib/components/ui/button';

  interface Props {
    /** Short statement of what failed, e.g. "Konnte nicht geladen werden". */
    title?: string;
    /** Details: cause and next step; never raw server output. */
    message: string;
    /** When given, shows the "Erneut versuchen" button. */
    onretry?: () => void;
    busy?: boolean;
    extra?: Snippet;
    class?: string;
  }
  let {
    title = t.states.errorTitle,
    message,
    onretry,
    busy = false,
    extra,
    class: className,
  }: Props = $props();
</script>

<div
  role="alert"
  class={cn(
    'bg-danger-soft border-danger/35 flex flex-col items-center gap-2 rounded-[var(--r-card)] border px-6 py-8 text-center',
    className,
  )}
>
  <span
    aria-hidden="true"
    class="bg-surface-card text-danger mb-1 flex size-11 items-center justify-center rounded-full shadow-sm"
    ><NavIcon name="danger" size={22} /></span
  >
  <p class="text-[length:var(--fs-h2)] leading-[26px] font-semibold">{title}</p>
  <p class="text-muted-foreground max-w-md text-[length:var(--fs-small)] leading-5">{message}</p>
  {#if onretry || extra}
    <div class="mt-2 flex flex-wrap justify-center gap-2">
      {#if onretry}<Button type="button" variant="outline" disabled={busy} onclick={onretry}
          >{t.states.retry}</Button
        >{/if}
      {@render extra?.()}
    </div>
  {/if}
</div>
