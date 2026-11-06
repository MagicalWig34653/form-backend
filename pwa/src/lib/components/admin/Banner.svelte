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
  const tones: Record<Tone, string> = {
    info: 'bg-info-soft border-info/30 text-foreground [&_svg.tone]:text-info',
    warn: 'bg-warn-soft border-warn/35 text-foreground [&_svg.tone]:text-warn',
    danger: 'bg-danger-soft border-danger/35 text-foreground [&_svg.tone]:text-danger',
    ok: 'bg-ok-soft border-ok/30 text-foreground [&_svg.tone]:text-ok',
  };
  const icons: Record<Tone, string> = { info: 'info', warn: 'warn', danger: 'danger', ok: 'check' };
</script>

<div
  role={tone === 'danger' ? 'alert' : 'status'}
  data-tone={tone}
  class={cn(
    'flex flex-wrap items-start gap-x-3 gap-y-2 rounded-[var(--r-card)] border px-4 py-3 text-[length:var(--fs-small)] leading-5',
    tones[tone],
    className,
  )}
>
  <span class="tone mt-0.5 shrink-0 [&>svg]:size-[18px]" aria-hidden="true"
    ><NavIcon name={icons[tone]} /></span
  >
  <div class="min-w-0 flex-1 basis-56">
    {#if title}<p class="font-semibold">{title}</p>{/if}
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
