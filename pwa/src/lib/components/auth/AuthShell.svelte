<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import Logo from '$lib/components/shell/Logo.svelte';

  interface Props {
    title: string;
    description?: string;
    /** Sentence under the logo (what the user is about to do). */
    intro?: string;
    children?: Snippet;
  }
  let { title, description, intro, children }: Props = $props();
</script>

<div class="w-full max-w-sm">
  <div class="mb-6 flex flex-col items-center gap-3 text-center">
    <Logo class="size-12" />
    <div>
      <p class="m-0 text-2xl leading-tight font-semibold tracking-tight">{t.app.name}</p>
      <p class="text-muted-foreground m-0 text-sm">{intro ?? t.shell.loginIntro}</p>
    </div>
  </div>
  <div data-slot="card" class="bg-card ring-foreground/10 rounded-xl p-6 ring-1">
    <h1 id="page-title" tabindex="-1" class="mb-1 text-xl leading-tight outline-none">
      {title}
    </h1>
    {#if description}<p class="ops-lead mb-0">{description}</p>{/if}
    <div class="mt-5 flex flex-col gap-4">{@render children?.()}</div>
  </div>
  <p class="text-muted-foreground mt-6 text-center text-xs">{t.auth.footer}</p>
</div>
