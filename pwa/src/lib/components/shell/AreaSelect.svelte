<script lang="ts">
  import { tick, untrack } from 'svelte';
  import NavIcon from './NavIcon.svelte';
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { formContext } from '$lib/formContext.svelte';
  import { formLists } from '$lib/formLists.svelte';
  import {
    areaEntryCount,
    areaLabel,
    areaPath,
    buildAreaGroups,
    flattenAreaOptions,
    SEARCH_THRESHOLD,
    type AreaOption,
  } from '$lib/area';
  import { step } from './palette';
  import { useNav } from './use-nav.svelte';

  let { onnavigate = () => {} }: { onnavigate?: () => void } = $props();
  const nav = useNav();

  let open = $state(false);
  let query = $state('');
  let active = $state(0);
  let root = $state<HTMLElement | null>(null);
  let trigger = $state<HTMLButtonElement | null>(null);
  let inputEl = $state<HTMLElement | null>(null);
  let listEl = $state<HTMLElement | null>(null);

  const area = $derived(nav.area);
  const tenants = $derived(session.tenants);
  const lists = $derived(formLists.states);
  // Search only pays off with many entries; the count is taken without a filter.
  const searchable = $derived(areaEntryCount(tenants, lists) > SEARCH_THRESHOLD);
  const groups = $derived(buildAreaGroups(tenants, lists, searchable ? query : ''));
  const options = $derived(flattenAreaOptions(groups, t.area.all, searchable ? query : ''));
  const current = $derived(
    areaLabel(area, tenants, lists, {
      all: t.area.all,
      customer: t.area.customer,
      form:
        area.kind === 'form' && formContext.form === area.form && formContext.name
          ? formContext.name
          : t.area.form,
    }),
  );
  const currentPath = $derived(areaPath(area));
  const activeId = $derived(options[active]?.id);
  const icon = (kind: 'all' | 'tenant' | 'form') =>
    kind === 'all' ? 'dashboard' : kind === 'tenant' ? 'customers' : 'forms';

  // The form name of the current area needs its customer's list; nothing else is loaded for the closed menu.
  $effect(() => {
    const a = area;
    if (a.kind === 'form')
      untrack(() => {
        formLists.bind(session.me?.id ?? null);
        void formLists.load(a.tenant);
      });
  });
  $effect(() => {
    void options.length;
    if (active >= options.length) active = Math.max(0, options.length - 1);
  });
  $effect(() => {
    if (open && activeId) document.getElementById(activeId)?.scrollIntoView?.({ block: 'nearest' });
  });

  async function show(): Promise<void> {
    open = true;
    query = '';
    const index = options.findIndex((o) => areaPath(o.area) === currentPath);
    active = Math.max(0, index);
    void formLists.ensure(tenants.map((c) => c.id));
    await tick();
    (searchable ? inputEl : listEl)?.focus();
  }
  function hide(restoreFocus: boolean): void {
    open = false;
    if (restoreFocus) void tick().then(() => trigger?.focus());
  }
  function choose(option: AreaOption): void {
    open = false;
    // The app moves focus to the new page heading after a navigation.
    router.navigate(areaPath(option.area));
    onnavigate();
  }
  function onkeydown(event: KeyboardEvent): void {
    const count = options.length;
    if (event.key === 'ArrowDown') active = step(active, 1, count);
    else if (event.key === 'ArrowUp') active = step(active, -1, count);
    else if (event.key === 'Home') active = 0;
    else if (event.key === 'End') active = Math.max(0, count - 1);
    else if (event.key === 'Enter') {
      const option = options[active];
      if (option) choose(option);
    } else if (event.key === 'Escape') hide(true);
    else if (event.key === 'Tab') hide(false);
    else return;
    event.stopPropagation();
    if (event.key !== 'Tab') event.preventDefault();
  }
  function triggerKey(event: KeyboardEvent): void {
    if (open || !['ArrowDown', 'ArrowUp'].includes(event.key)) return;
    event.preventDefault();
    void show();
  }
  function focusout(event: FocusEvent): void {
    const next = event.relatedTarget as Node | null;
    if (open && next && root && !root.contains(next)) open = false;
  }
  function pointerdown(event: PointerEvent): void {
    if (open && root && !root.contains(event.target as Node)) open = false;
  }

  const optionClass = (selected: boolean, isActive: boolean, depth: number) =>
    cn(
      'flex min-h-10 w-full cursor-pointer items-center gap-2 rounded-md px-2.5 py-2 text-left text-sm lg:min-h-9 lg:py-1.5',
      depth > 0 && 'pl-7',
      isActive && 'bg-muted',
      selected && 'bg-secondary font-medium',
    );
</script>

<svelte:window onpointerdown={pointerdown} />

{#snippet row(option: AreaOption, kind: 'all' | 'tenant' | 'form', note?: string)}
  {@const selected = areaPath(option.area) === currentPath}
  <!-- svelte-ignore a11y_click_events_have_key_events -->
  <div
    id={option.id}
    role="option"
    tabindex="-1"
    aria-selected={selected}
    data-area-option={kind}
    class={optionClass(selected, option.id === activeId, kind === 'form' ? 1 : 0)}
    onpointerdown={(e) => e.preventDefault()}
    onclick={() => choose(option)}
    onmousemove={() => {
      const i = options.findIndex((o) => o.id === option.id);
      if (i >= 0) active = i;
    }}
  >
    <span aria-hidden="true" class="text-muted-foreground flex w-[18px] shrink-0 justify-center"
      ><NavIcon name={icon(kind)} size={kind === 'form' ? 15 : 17} /></span
    >
    <span class="min-w-0 flex-1">
      <span class="block truncate">{option.label}</span>
      {#if note}<span class="text-muted-foreground block text-xs font-normal">{note}</span>{/if}
    </span>
    {#if selected}<span aria-hidden="true" class="text-brand-ink shrink-0"
        ><NavIcon name="check" size={15} /></span
      >{/if}
  </div>
{/snippet}

<div class="relative mb-2" bind:this={root} onfocusout={focusout}>
  <span id="area-label" class="text-muted-foreground block px-1 pb-1 text-xs font-medium"
    >{t.area.label}</span
  >
  <button
    type="button"
    id="area-trigger"
    data-testid="area-trigger"
    bind:this={trigger}
    aria-haspopup="listbox"
    aria-expanded={open}
    aria-controls="area-list"
    aria-labelledby={current.kind === 'form'
      ? 'area-label area-value area-tenant'
      : 'area-label area-value'}
    onclick={() => (open ? hide(false) : void show())}
    onkeydown={triggerKey}
    class="border-input hover:bg-muted flex min-h-10 w-full items-center gap-2 rounded-lg border px-3 text-sm transition-colors"
  >
    <span aria-hidden="true" class="text-muted-foreground flex w-[18px] shrink-0 justify-center"
      ><NavIcon name={icon(current.kind)} size={17} /></span
    >
    <span class="min-w-0 flex-1 text-left">
      <span id="area-value" class="block truncate font-medium">{current.label}</span>
      {#if current.kind === 'form' && current.tenantName}
        <span id="area-tenant" class="text-muted-foreground block truncate text-xs"
          >{current.tenantName}</span
        >
      {/if}
    </span>
    <span aria-hidden="true" class="text-muted-foreground shrink-0"
      ><NavIcon name="updown" size={16} /></span
    >
  </button>
  {#if open}
    <div
      class="bg-popover border-border absolute inset-x-0 top-full z-50 mt-1 flex max-h-[min(24rem,60vh)] flex-col overflow-hidden rounded-lg border"
    >
      {#if searchable}
        <div class="border-border border-b p-2">
          <input
            type="text"
            role="combobox"
            aria-expanded="true"
            aria-controls="area-list"
            aria-autocomplete="list"
            aria-activedescendant={activeId}
            aria-label={t.area.search}
            placeholder={t.area.search}
            autocomplete="off"
            spellcheck="false"
            bind:this={inputEl}
            bind:value={query}
            {onkeydown}
            oninput={() => (active = 0)}
            class="border-input bg-background h-9 w-full rounded-md border px-2.5 text-sm"
          />
        </div>
      {/if}
      <p role="status" class="text-muted-foreground px-3.5 py-2 text-sm empty:hidden">
        {options.length === 0 ? t.area.noMatch : ''}
      </p>
      <div
        id="area-list"
        role="listbox"
        aria-label={t.area.listLabel}
        aria-activedescendant={searchable ? undefined : activeId}
        tabindex={searchable ? undefined : 0}
        bind:this={listEl}
        onkeydown={searchable ? undefined : onkeydown}
        class="min-h-0 flex-1 overflow-y-auto p-1 focus-visible:outline-offset-[-2px]"
      >
        {#each options.slice(0, 1).filter((o) => o.area.kind === 'all') as option (option.id)}
          {@render row(option, 'all', t.area.allHint)}
        {/each}
        {#each groups as group (group.id)}
          <div role="group" aria-label={group.head.label}>
            {@render row(
              group.head,
              'tenant',
              group.failed ? t.area.formsFailed : group.loading ? t.area.formsLoading : undefined,
            )}
            {#each group.forms as form (form.id)}{@render row(form, 'form')}{/each}
          </div>
        {/each}
      </div>
    </div>
  {/if}
</div>
