<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';

  interface Props {
    title: string;
    description?: string;
    /** Sentence under the logo (what the user is about to do). */
    intro?: string;
    children?: Snippet;
  }
  let { title, description, intro, children }: Props = $props();
</script>

<!-- Single root: App's `.auth-stage > *` rule sizes it to the card width. -->
<div class="relative isolate">
  <div
    aria-hidden="true"
    class="pointer-events-none absolute -top-16 left-1/2 -z-10 h-56 w-full -translate-x-1/2 rounded-full opacity-70 blur-3xl"
    style="background: radial-gradient(closest-side, color-mix(in srgb, var(--ui-accent) 22%, transparent), transparent)"
  ></div>
  <div class="auth-rise mb-6 flex flex-col items-center gap-3 text-center">
    <svg
      viewBox="0 0 64 64"
      class="size-14 rounded-2xl shadow-[var(--shadow-card)]"
      role="img"
      aria-label={t.auth.logoLabel}
    >
      <defs>
        <linearGradient id="auth-logo-fill" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="var(--ui-accent)" />
          <stop offset="1" stop-color="var(--ui-accent-ink)" />
        </linearGradient>
      </defs>
      <rect width="64" height="64" rx="14" fill="url(#auth-logo-fill)" />
      <path d="M18 18h28v6H18zm0 11h28v6H18zm0 11h18v6H18z" fill="#fff" />
    </svg>
    <p class="text-ui-accent-ink text-xs font-semibold tracking-widest uppercase">
      {t.shell.secure}
    </p>
    <p class="text-muted-foreground max-w-xs text-sm">{intro ?? t.shell.loginIntro}</p>
  </div>
  <div class="surface-card p-6 shadow-lg sm:p-8" style="--i: 1">
    <h1 id="page-title" tabindex="-1" class="text-2xl leading-tight font-semibold outline-none">
      {title}
    </h1>
    {#if description}<p class="text-muted-foreground mt-1.5 text-sm leading-5">
        {description}
      </p>{/if}
    <div class="mt-5 flex flex-col gap-4">{@render children?.()}</div>
  </div>
  <p class="text-muted-foreground mt-6 text-center text-xs">{t.auth.footer}</p>
</div>

<style>
  /* Transform-only entrance: text keeps full opacity so contrast checks never see a half-faded state. */
  @keyframes auth-rise {
    from {
      transform: translateY(8px);
    }
  }
  .auth-rise {
    animation: auth-rise 300ms ease-out both;
  }
  :global(html[data-effects='off']) .auth-rise {
    animation: none;
  }
</style>
