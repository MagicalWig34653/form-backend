<script lang="ts">
  import { tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import AppearanceMenu from '$lib/components/shell/AppearanceMenu.svelte';
  import Login from './routes/Login.svelte';
  import Setup from './routes/Setup.svelte';
  import NotFound from './routes/NotFound.svelte';
  import Shell from './routes/admin/Shell.svelte';
  import { matchRoute } from '$lib/routes';

  // Public documentation site (GitHub Pages); override per deployment with VITE_DOCS_URL.
  const docsUrl: string =
    import.meta.env.VITE_DOCS_URL ?? 'https://magicalwig34653.github.io/form-backend/';

  $effect(() => {
    if (router.path === '/') router.navigate('/t', true);
  });

  // Move focus to the page heading after client-side navigation (screen readers).
  let first = true;
  $effect(() => {
    void router.path;
    if (first) {
      first = false;
      return;
    }
    void tick().then(() => document.getElementById('page-title')?.focus());
  });
</script>

<a
  href="#main"
  class="bg-primary text-primary-foreground sr-only z-50 rounded-md px-3 py-2 focus:not-sr-only focus:absolute focus:top-2 focus:left-2"
>
  {t.app.skipToContent}
</a>

{#if router.path === '/login' || router.path === '/setup'}
  <header
    class="border-border flex flex-wrap items-center justify-between gap-2 border-b px-4 py-3"
  >
    <span class="font-semibold">{t.app.name}</span>
    <div class="flex items-center gap-1">
      <a
        href={docsUrl}
        target="_blank"
        rel="noopener noreferrer"
        class="text-muted-foreground hover:text-foreground focus-visible:ring-ring rounded-md px-3 py-2 text-sm underline-offset-4 hover:underline focus-visible:ring-2 focus-visible:outline-none"
        aria-label={t.app.docsHint}>{t.app.docs}</a
      >
      <AppearanceMenu />
    </div>
  </header>
{/if}

<main
  id="main"
  class={router.path === '/login' || router.path === '/setup' ? 'auth-stage' : 'min-h-dvh'}
>
  {#if router.path === '/login'}
    <Login />
  {:else if router.path === '/setup'}
    <Setup />
  {:else if router.path !== '/' && matchRoute(router.path).name !== 'notFound'}
    <Shell />
  {:else if router.path !== '/'}
    <NotFound />
  {/if}
</main>
