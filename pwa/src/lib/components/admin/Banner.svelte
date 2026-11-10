<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  type Tone = 'info' | 'warn' | 'danger' | 'ok';
  interface Props {
    tone?: Tone;
    title?: string;
    /** Show a close button; called when the user dismisses the banner. */
    ondismiss?: () => void;
    action?: Snippet;
    children?: Snippet;
    class?: string;
  }
  let { tone = 'info', title, ondismiss, action, children, class: className }: Props = $props();
  // Getönte Hinweiskästen: nie volle Farbflächen; Zustand zusätzlich über Symbol und Text.
  const tones: Record<Tone, string> = {
    info: 'bg-blue-500/10 ring-blue-500/40 [&_svg.tone]:text-blue-700 dark:[&_svg.tone]:text-blue-400',
    warn: 'bg-amber-500/10 ring-amber-500/50 [&_svg.tone]:text-amber-700 dark:[&_svg.tone]:text-amber-400',
    danger: 'bg-destructive/10 ring-destructive/40 [&_svg.tone]:text-destructive',
    ok: 'bg-emerald-500/10 ring-emerald-500/40 [&_svg.tone]:text-emerald-700 dark:[&_svg.tone]:text-emerald-400',
  };
  const icons: Record<Tone, string> = { info: 'info', warn: 'warn', danger: 'danger', ok: 'check' };
</script>

<div
  role={tone === 'danger' ? 'alert' : 'status'}
  data-tone={tone}
  class={cn(
    'text-foreground flex flex-wrap items-start gap-x-3 gap-y-2 rounded-lg px-3.5 py-2.5 ring-1 ring-inset text-sm leading-5',
    tones[tone],
    className,
  )}
>
  <span class="tone mt-0.5 shrink-0 [&>svg]:size-[18px]" aria-hidden="true"
    ><NavIcon name={icons[tone]} /></span
  >
  <div class="min-w-0 flex-1 basis-56">
    {#if title}<p class="m-0 font-semibold">{title}</p>{/if}
    <div>{@render children?.()}</div>
  </div>
  {#if action}<div class="flex shrink-0 items-center gap-2">{@render action()}</div>{/if}
  {#if ondismiss}
    <button
      type="button"
      onclick={ondismiss}
      aria-label={t.ui.dismiss}
      class="hover:bg-foreground/10 -m-1 flex size-8 shrink-0 items-center justify-center rounded-md"
      ><NavIcon name="x" size={16} /></button
    >
  {/if}
</div>
