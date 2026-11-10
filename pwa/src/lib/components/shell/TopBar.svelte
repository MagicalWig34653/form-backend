<script lang="ts">
  import { t } from '$lib/i18n';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import Breadcrumb from '$lib/components/admin/Breadcrumb.svelte';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { router } from '$lib/router.svelte';
  import { connectivity } from '$lib/online.svelte';
  import AppearanceMenu from './AppearanceMenu.svelte';
  import NavIcon from './NavIcon.svelte';
  import { crumbsFor } from './nav';
  import { shellState } from './shell-state.svelte';
  import { useNav } from './use-nav.svelte';

  const nav = useNav();
  const isMac = typeof navigator !== 'undefined' && /mac|iphone|ipad/i.test(navigator.platform);
  const shortcut = isMac ? t.palette.shortcutMac : t.palette.shortcut;
  // Wie im thermoctl-Design beginnt der Pfad mit dem Namen der Anwendung.
  const crumbs = $derived([
    { label: t.app.name, href: '/overview' },
    ...crumbsFor(
      nav.route,
      session.tenants,
      nav.groups.flatMap((g) => g.items),
    ),
  ]);
</script>

<header
  class="app-topbar sticky top-0 z-20 flex min-h-[60px] items-center justify-between gap-3 border-b px-4 py-2 sm:px-7"
>
  <div class="flex min-w-0 flex-1 items-center gap-2">
    <Button
      id="drawer-trigger"
      variant="ghost"
      size="icon"
      class="lg:hidden"
      aria-label={t.shell.menu}
      aria-haspopup="dialog"
      aria-expanded={shellState.drawerOpen}
      onclick={() => (shellState.drawerOpen = !shellState.drawerOpen)}
      ><NavIcon name="panel" size={18} /></Button
    >
    <Breadcrumb items={crumbs} class="min-w-0" />
  </div>
  <div class="flex items-center gap-1">
    <Button
      variant="outline"
      class="text-muted-foreground max-sm:size-10 max-sm:p-0 sm:min-w-40 sm:justify-start"
      aria-label={`${t.shell.search} ${shortcut}`}
      aria-haspopup="dialog"
      onclick={() => (shellState.paletteOpen = true)}
      ><NavIcon name="search" size={16} /><span class="max-sm:sr-only">{t.shell.search}</span><kbd
        class="text-muted-foreground ml-auto text-xs max-md:hidden">{shortcut}</kbd
      ></Button
    >
    {#if !connectivity.online}
      <span
        role="status"
        class="flex min-h-9 items-center gap-1.5 rounded-full border border-amber-500/50 bg-amber-500/10 px-3 text-sm font-medium"
        ><NavIcon name="warn" size={15} />{t.shell.offline}</span
      >
    {/if}
    <a
      href="/account"
      onclick={(e) => {
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
        e.preventDefault();
        router.navigate('/account');
      }}
      title={keyring.unlocked ? t.shell.keyUnlockedHint : t.shell.keyLockedHint}
      class={`flex min-h-9 items-center gap-1.5 rounded-full border px-3 text-sm font-medium ${keyring.unlocked ? 'text-muted-foreground' : 'border-amber-500/50 bg-amber-500/10'}`}
      ><NavIcon name={keyring.unlocked ? 'unlocked' : 'locked'} size={15} /><span
        class="max-sm:sr-only">{keyring.unlocked ? t.shell.keyUnlocked : t.shell.keyLocked}</span
      ></a
    >
    <AppearanceMenu />
  </div>
</header>
