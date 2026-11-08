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
    'bg-destructive/10 border-destructive/40 flex flex-col items-center gap-2 rounded-xl border px-6 py-8 text-center',
    className,
  )}
>
  <span
    aria-hidden="true"
    class="bg-background text-destructive mb-1 flex size-11 items-center justify-center rounded-full"
    ><NavIcon name="danger" size={22} /></span
  >
  <p class="m-0 text-[17px] leading-snug font-semibold">{title}</p>
  <p class="text-muted-foreground m-0 max-w-md text-sm leading-5">{message}</p>
  {#if onretry || extra}
    <div class="mt-2 flex flex-wrap justify-center gap-2">
      {#if onretry}<Button type="button" variant="outline" disabled={busy} onclick={onretry}
          >{t.states.retry}</Button
        >{/if}
      {@render extra?.()}
    </div>
  {/if}
</div>
