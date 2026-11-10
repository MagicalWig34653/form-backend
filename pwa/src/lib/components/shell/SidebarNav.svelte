<script lang="ts">
  import { tick } from 'svelte';
  import NavIcon from './NavIcon.svelte';
  import Logo from './Logo.svelte';
  import HelpDialog from './HelpDialog.svelte';
  import AreaSelect from './AreaSelect.svelte';
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import { session } from '$lib/session.svelte';
  import { followLink, useNav } from './use-nav.svelte';
  import { shellState } from './shell-state.svelte';
  import type { NavItem } from './nav';

  let { onnavigate = () => {} }: { onnavigate?: () => void } = $props();
  const nav = useNav();
  const isMac = typeof navigator !== 'undefined' && /mac|iphone|ipad/i.test(navigator.platform);
  const shortcut = isMac ? t.palette.shortcutMac : t.palette.shortcut;

  let navEl = $state<HTMLElement | null>(null);
  function keydown(event: KeyboardEvent) {
    if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) || !navEl) return;
    const items = [...navEl.querySelectorAll<HTMLElement>('[data-nav-item]')];
    const current = items.indexOf(document.activeElement as HTMLElement);
    const last = items.length - 1;
    const index =
      event.key === 'Home'
        ? 0
        : event.key === 'End'
          ? last
          : event.key === 'ArrowDown'
            ? Math.min(last, current + 1)
            : Math.max(0, current - 1);
    const target = items[index];
    if (!target) return;
    event.preventDefault();
    target.focus();
  }

  // The target page may still be loading: wait briefly for the element, then scroll to it.
  function scrollToWhenPresent(id: string, tries = 40): void {
    void tick().then(() => {
      const el = document.getElementById(id);
      if (el) setTimeout(() => el.scrollIntoView?.({ block: 'start' }), 50);
      else if (tries > 0) setTimeout(() => scrollToWhenPresent(id, tries - 1), 50);
    });
  }

  function navigate(event: MouseEvent, href: string) {
    if (!followLink(event, href)) return;
    const hash = href.split('#')[1];
    if (hash) scrollToWhenPresent(hash);
    onnavigate();
  }
  const link =
    'hover:bg-muted flex min-h-10 w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-left text-sm lg:min-h-9 lg:py-1.5 focus-visible:outline-offset-[-2px]';
</script>

{#snippet entry(item: NavItem)}
  <a
    data-nav-item
    href={item.href}
    onclick={(e) => navigate(e, item.href)}
    aria-current={item.active ? 'page' : undefined}
    title={item.hint}
    class={cn(link, item.active && 'bg-secondary font-medium')}
  >
    <span aria-hidden="true" class="text-muted-foreground flex w-[18px] shrink-0 justify-center"
      ><NavIcon name={item.icon} /></span
    >
    <span class="min-w-0 truncate">{item.label}</span>
  </a>
{/snippet}

<div class="flex h-full min-h-0 flex-col">
  <a
    href="/overview"
    onclick={(e) => navigate(e, '/overview')}
    class="hover:border-border hover:bg-muted mb-3 flex items-center gap-2.5 rounded-lg border border-transparent px-2 py-2"
  >
    <Logo />
    <strong class="text-[15px] tracking-tight">{t.app.name}</strong>
  </a>
  <AreaSelect {onnavigate} />
  <button
    type="button"
    onclick={() => {
      shellState.paletteOpen = true;
      onnavigate();
    }}
    aria-label={`${t.shell.search} ${shortcut}`}
    aria-haspopup="dialog"
    class="border-input text-muted-foreground hover:bg-muted mb-1 flex h-10 w-full items-center gap-2 rounded-lg border px-3 text-sm transition-colors"
  >
    <NavIcon name="search" size={16} /><span class="flex-1 text-left">{t.shell.search}</span>
  </button>
  <!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
  <nav
    aria-label={t.shell.navigation}
    class="min-h-0 flex-1 overflow-y-auto"
    bind:this={navEl}
    onkeydown={keydown}
  >
    {#each nav.groups as group (group.id)}
      <div
        id={`nav-heading-${group.id}`}
        class="text-muted-foreground px-2.5 pt-4 pb-1.5 text-xs font-medium"
      >
        {group.label}
      </div>
      <div role="group" aria-labelledby={`nav-heading-${group.id}`} class="flex flex-col gap-0.5">
        {#each group.items as item (item.id)}{@render entry(item)}{/each}
      </div>
    {/each}
  </nav>
  <div class="mt-auto border-t pt-3">
    {@render entry(nav.account)}
    <HelpDialog class={link} />
    <button type="button" class={link} onclick={() => void session.logout()}>
      <span aria-hidden="true" class="text-muted-foreground flex w-[18px] shrink-0 justify-center"
        ><NavIcon name="logout" /></span
      >{t.admin.logout}
    </button>
  </div>
</div>
