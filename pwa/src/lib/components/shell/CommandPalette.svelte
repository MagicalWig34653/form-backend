<script lang="ts">
  import { Dialog as DialogPrimitive } from 'bits-ui';
  import { Dialog } from '$lib/components/ui/dialog';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { FormListItem } from '$lib/api/admin';
  import { formPath, tenantPath } from '$lib/routes';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { theme } from '$lib/theme.svelte';
  import NavIcon from './NavIcon.svelte';
  import { shellState } from './shell-state.svelte';
  import { useNav } from './use-nav.svelte';
  import { filterItems, groupItems, step, type PaletteGroupId, type PaletteItem } from './palette';

  const nav = useNav();
  const groupOrder: PaletteGroupId[] = ['pages', 'forms', 'customers', 'actions'];
  const groupLabels: Record<PaletteGroupId, string> = {
    pages: t.palette.groupPages,
    forms: t.palette.groupForms,
    customers: t.palette.groupCustomers,
    actions: t.palette.groupActions,
  };

  let query = $state('');
  let active = $state(0);
  let formsByTenant = $state<Record<string, FormListItem[]>>({});
  let formsLoading = $state(false);
  let opener: Element | null = null;
  let navigated = false;

  // Remember where focus was before the dialog mounts, to give it back on Escape.
  $effect.pre(() => {
    if (shellState.paletteOpen) opener ??= document.activeElement;
  });
  $effect(() => {
    if (!shellState.paletteOpen) return;
    query = '';
    active = 0;
    navigated = false;
    const tenant = nav.tenant;
    if (!tenant || formsByTenant[tenant]) return;
    formsLoading = true;
    void adminApi.forms(tenant).then((r) => {
      formsLoading = false;
      if (r.ok) formsByTenant = { ...formsByTenant, [tenant]: r.data.items };
    });
  });

  const items = $derived.by<PaletteItem[]>(() => {
    const list: PaletteItem[] = [];
    for (const group of nav.groups)
      for (const item of group.items.filter((i) => !i.disabled))
        list.push({
          id: `page-${item.id}`,
          group: 'pages',
          label: item.label,
          hint: group.label,
          icon: item.icon,
          href: item.href,
        });
    list.push({
      id: 'page-account',
      group: 'pages',
      label: nav.account.label,
      hint: t.palette.groupPages,
      icon: 'account',
      href: nav.account.href,
    });
    const tenant = nav.tenant;
    for (const form of tenant ? (formsByTenant[tenant] ?? []) : []) {
      list.push({
        id: `form-${form.id}`,
        group: 'forms',
        label: form.name,
        hint: t.palette.formKind,
        icon: 'forms',
        href: formPath(tenant as string, form.id),
      });
      list.push({
        id: `entries-${form.id}`,
        group: 'forms',
        label: t.palette.entriesOf.replace('{name}', form.name),
        hint: t.palette.formKind,
        icon: 'entries',
        keywords: form.name,
        href: formPath(tenant as string, form.id, 'entries'),
      });
    }
    for (const customer of session.tenants)
      list.push({
        id: `customer-${customer.id}`,
        group: 'customers',
        label: customer.name,
        hint: t.palette.customerKind,
        icon: 'customers',
        href: tenantPath(customer.id),
      });
    list.push(
      {
        id: 'action-theme',
        group: 'actions',
        label: t.palette.toggleTheme,
        icon: 'appearance',
        keywords: 'dunkel hell modus design',
        run: () => theme.toggle(),
      },
      {
        id: 'action-logout',
        group: 'actions',
        label: t.palette.logout,
        icon: 'logout',
        keywords: 'abmelden ausloggen',
        run: () => void session.logout(),
      },
    );
    return list;
  });
  const visible = $derived(filterItems(items, query));
  const groups = $derived(groupItems(visible, groupOrder));
  const flat = $derived(groups.flatMap((g) => g.items));
  const activeId = $derived.by(() => {
    const current = flat[active];
    return current ? `palette-opt-${current.id}` : undefined;
  });
  $effect(() => {
    void query;
    active = 0;
  });
  $effect(() => {
    if (activeId) document.getElementById(activeId)?.scrollIntoView?.({ block: 'nearest' });
  });

  function choose(item: PaletteItem): void {
    navigated = item.href !== undefined;
    shellState.paletteOpen = false;
    if (item.href) router.navigate(item.href);
    else item.run?.();
  }
  function onkeydown(event: KeyboardEvent): void {
    const count = flat.length;
    if (event.key === 'ArrowDown') active = step(active, 1, count);
    else if (event.key === 'ArrowUp') active = step(active, -1, count);
    else if (event.key === 'Home') active = 0;
    else if (event.key === 'End') active = Math.max(0, count - 1);
    else if (event.key === 'Enter') {
      const item = flat[active];
      if (item) choose(item);
    } else return;
    event.preventDefault();
  }
  function globalKey(event: KeyboardEvent): void {
    if (
      event.key.toLowerCase() === 'k' &&
      (event.metaKey || event.ctrlKey) &&
      !event.altKey &&
      !event.shiftKey
    ) {
      event.preventDefault();
      shellState.togglePalette();
    }
  }
  function closeFocus(event: Event): void {
    event.preventDefault();
    const target = opener;
    opener = null;
    // After a navigation the app moves focus to the new page heading.
    if (!navigated && target instanceof HTMLElement && target.isConnected) target.focus();
  }
</script>

<svelte:window onkeydown={globalKey} />

<Dialog bind:open={shellState.paletteOpen}>
  <DialogPrimitive.Portal>
    <DialogPrimitive.Overlay class="fixed inset-0 z-50 bg-black/50 backdrop-blur-[2px]" />
    <DialogPrimitive.Content
      onCloseAutoFocus={closeFocus}
      class="bg-surface-raised border-border-subtle fixed top-[12vh] left-1/2 z-50 flex max-h-[70vh] w-[calc(100%-2rem)] max-w-xl -translate-x-1/2 flex-col overflow-hidden rounded-[var(--r-pop)] border shadow-[var(--shadow-pop)]"
    >
      <DialogPrimitive.Title class="sr-only">{t.palette.title}</DialogPrimitive.Title>
      <DialogPrimitive.Description class="sr-only"
        >{t.palette.description}</DialogPrimitive.Description
      >
      <div class="border-border-subtle flex items-center gap-3 border-b px-4">
        <span class="text-muted-foreground" aria-hidden="true"
          ><NavIcon name="search" size={18} /></span
        >
        <input
          type="text"
          role="combobox"
          aria-expanded="true"
          aria-controls="palette-list"
          aria-activedescendant={activeId}
          aria-autocomplete="list"
          aria-label={t.palette.inputLabel}
          placeholder={t.palette.placeholder}
          autocomplete="off"
          spellcheck="false"
          bind:value={query}
          {onkeydown}
          class="placeholder:text-muted-foreground min-h-14 flex-1 bg-transparent text-base outline-none"
        />
      </div>
      <div
        id="palette-list"
        role="listbox"
        aria-label={t.palette.results}
        class="flex-1 overflow-y-auto p-2"
      >
        {#each groups as group (group.id)}
          <div role="group" aria-labelledby={`palette-group-${group.id}`} class="mb-1">
            <p
              id={`palette-group-${group.id}`}
              class="text-muted-foreground px-3 pt-2 pb-1 text-[length:var(--fs-micro)] font-semibold tracking-[0.06em] uppercase"
            >
              {groupLabels[group.id]}
            </p>
            {#each group.items as item (item.id)}
              {@const selected = flat[active]?.id === item.id}
              <!-- Options are pointer targets only; the keyboard path is the combobox input. -->
              <!-- svelte-ignore a11y_click_events_have_key_events -->
              <div
                id={`palette-opt-${item.id}`}
                role="option"
                aria-selected={selected}
                tabindex="-1"
                onclick={() => choose(item)}
                onmousemove={() => (active = flat.findIndex((x) => x.id === item.id))}
                class="flex min-h-11 cursor-pointer items-center gap-3 rounded-[var(--r-ctl)] px-3 text-[length:var(--fs-body)] aria-selected:bg-ui-accent-soft aria-selected:text-ui-accent-ink"
              >
                <span aria-hidden="true" class="text-muted-foreground"
                  ><NavIcon name={item.icon} size={17} /></span
                >
                <span class="min-w-0 flex-1 truncate">{item.label}</span>
                {#if item.hint}<span
                    class="text-muted-foreground shrink-0 text-[length:var(--fs-small)]"
                    >{item.hint}</span
                  >{/if}
              </div>
            {/each}
          </div>
        {/each}
        {#if flat.length === 0}
          <p
            role="status"
            class="text-muted-foreground px-3 py-8 text-center text-[length:var(--fs-small)]"
          >
            {formsLoading ? t.palette.formsLoading : t.palette.empty}
          </p>
        {/if}
      </div>
      <p role="status" class="sr-only">
        {flat.length === 0 ? '' : t.palette.count.replace('{n}', String(flat.length))}
      </p>
      <p
        class="text-muted-foreground border-border-subtle border-t px-4 py-2 text-[length:var(--fs-micro)]"
      >
        {t.palette.hintsLabel}
      </p>
    </DialogPrimitive.Content>
  </DialogPrimitive.Portal>
</Dialog>
