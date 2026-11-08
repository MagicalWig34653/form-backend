<script lang="ts">
  import { tick } from 'svelte';
  import NavIcon from './NavIcon.svelte';
  import HelpDialog from './HelpDialog.svelte';
  import VersionInfo from './VersionInfo.svelte';
  import { t } from '$lib/i18n';
  import { session } from '$lib/session.svelte';
  import { followLink, useNav } from './use-nav.svelte';
  import { shellState } from './shell-state.svelte';
  import type { NavItem } from './nav';

  let { onnavigate = () => {} }: { onnavigate?: () => void } = $props();
  const nav = useNav();
  const isMac = typeof navigator !== 'undefined' && /mac|iphone|ipad/i.test(navigator.platform);
  const shortcut = isMac ? t.palette.shortcutMac : t.palette.shortcut;

  function navigate(event: MouseEvent, href: string) {
    if (!followLink(event, href)) return;
    if (href.endsWith('#statistics'))
      void tick().then(() => document.getElementById('statistics')?.scrollIntoView());
    onnavigate();
  }
  const linkClass =
    'text-muted-foreground hover:bg-surface-sunken hover:text-foreground aria-[current=page]:bg-ui-accent-soft aria-[current=page]:text-ui-accent-ink group flex min-h-11 items-center gap-3 rounded-[var(--r-ctl)] px-3 text-[length:var(--fs-body)] font-medium transition-colors md:min-h-9';
</script>

{#snippet link(item: NavItem)}
  {#if item.disabled}
    <span
      aria-disabled="true"
      title={item.hint}
      class="text-muted-foreground/60 flex min-h-11 cursor-not-allowed items-center gap-3 rounded-[var(--r-ctl)] px-3 text-[length:var(--fs-body)] font-medium md:min-h-9"
      ><span aria-hidden="true" class="flex w-5 justify-center"><NavIcon name={item.icon} /></span
      >{item.label}</span
    >
  {:else}
    <a
      href={item.href}
      onclick={(e) => navigate(e, item.href)}
      aria-current={item.active ? 'page' : undefined}
      title={item.hint}
      class={linkClass}
      ><span aria-hidden="true" class="flex w-5 justify-center"><NavIcon name={item.icon} /></span
      >{item.label}</a
    >
  {/if}
{/snippet}

<div class="flex h-full flex-col">
  <a
    href="/t"
    onclick={(e) => navigate(e, '/t')}
    class="flex items-center gap-3 px-5 pt-5 pb-4 font-semibold tracking-tight"
    ><span
      class="text-ui-accent-ink bg-ui-accent-soft border-border-subtle flex size-9 items-center justify-center rounded-xl border"
      aria-hidden="true">▤</span
    >{t.app.name}</a
  >
  <div class="px-3 pb-3">
    <button
      type="button"
      onclick={() => {
        shellState.paletteOpen = true;
        onnavigate();
      }}
      aria-label={`${t.shell.search} ${shortcut}`}
      aria-haspopup="dialog"
      class="bg-surface-card border-border-subtle text-muted-foreground hover:border-border flex min-h-11 w-full items-center gap-2 rounded-[var(--r-ctl)] border px-3 text-[length:var(--fs-body)] shadow-[var(--shadow-card)] transition-colors md:min-h-10"
    >
      <NavIcon name="search" size={16} /><span class="flex-1 text-left">{t.shell.search}</span>
      <kbd
        class="border-border-subtle bg-surface-sunken hidden rounded-md border px-1.5 py-0.5 font-sans text-[length:var(--fs-micro)] md:inline"
        aria-hidden="true">{shortcut}</kbd
      >
    </button>
  </div>
  <nav aria-label={t.shell.navigation} class="flex flex-1 flex-col gap-4 overflow-y-auto px-3 pb-3">
    {#each nav.groups as group (group.id)}
      <div class="flex flex-col gap-0.5">
        <p
          class="text-muted-foreground px-3 pb-1 text-[length:var(--fs-micro)] font-semibold tracking-[0.06em] uppercase"
        >
          {group.label}
        </p>
        {#each group.items as item (item.id)}{@render link(item)}{/each}
      </div>
    {/each}
  </nav>
  <div class="border-border-subtle flex flex-col gap-0.5 border-t px-3 py-3">
    {@render link(nav.account)}
    <HelpDialog />
    <div class="text-muted-foreground flex items-center justify-between gap-2 px-3 pt-2 text-xs">
      <span class="min-w-0 truncate">
        {t.admin.signedInAs.replace('{name}', session.me?.username ?? '')}
      </span>
      <VersionInfo />
    </div>
  </div>
</div>
