<script lang="ts" module>
  export interface PageTab {
    id: string;
    label: string;
    href: string;
    /** Marks the current page; exactly one tab should be active. */
    active: boolean;
    /** Dot indicator, e.g. "draft differs from live" (the label gets a hidden explanation). */
    dot?: string;
  }
</script>

<script lang="ts">
  import { tick } from 'svelte';
  import { router } from '$lib/router.svelte';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    /** Accessible name of the tab navigation. */
    label: string;
    tabs: PageTab[];
    class?: string;
  }
  let { label, tabs, class: className }: Props = $props();
  let list = $state<HTMLElement | null>(null);
  let more = $state({ left: false, right: false });
  /** Shows a fade and arrow on the side where further tabs are hidden. */
  function measure(): void {
    if (!list) return;
    const max = list.scrollWidth - list.clientWidth;
    more = { left: list.scrollLeft > 4, right: list.scrollLeft < max - 4 };
  }
  function scrollBy(direction: 1 | -1): void {
    list?.scrollBy?.({ left: direction * 160, behavior: 'smooth' });
  }
  $effect(() => {
    void tabs.length;
    if (!list) return;
    measure();
    const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(measure);
    observer?.observe(list);
    return () => observer?.disconnect();
  });

  function go(event: MouseEvent, href: string): void {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    router.navigate(href);
  }
  // Tabs scroll sideways on narrow screens; the current one is brought into view after navigation.
  $effect(() => {
    void tabs.map((x) => x.active).join();
    void tick().then(() => {
      const current = list?.querySelector<HTMLElement>('[aria-current="page"]');
      if (!list || !current?.parentElement) return;
      // Centre the current tab so that the overflow arrows never cover it.
      const item = current.parentElement;
      const left = item.offsetLeft - (list.clientWidth - item.offsetWidth) / 2;
      list.scrollTo?.({ left: Math.max(0, left) });
    });
  });
</script>

<nav aria-label={label} class={cn('border-border relative -mb-px min-w-0 border-b', className)}>
  <ul
    bind:this={list}
    onscroll={measure}
    class="m-0 flex list-none snap-x snap-proximity scroll-px-10 gap-1 overflow-x-auto p-0 pb-px [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
  >
    {#each tabs as tab (tab.id)}
      <li class="shrink-0 snap-start">
        <a
          href={tab.href}
          aria-current={tab.active ? 'page' : undefined}
          onclick={(e) => go(e, tab.href)}
          class={cn(
            'focus-visible:ring-ring/50 relative inline-flex min-h-11 items-center gap-1.5 rounded-t-md px-3 text-sm font-medium whitespace-nowrap transition-colors outline-none focus-visible:ring-3 lg:min-h-10',
            tab.active
              ? "text-foreground after:bg-brand after:absolute after:inset-x-2 after:-bottom-px after:h-0.5 after:rounded-full after:content-['']"
              : 'text-muted-foreground hover:text-foreground',
          )}
          >{tab.label}{#if tab.dot}<span
              aria-hidden="true"
              class="bg-brand inline-block size-1.5 rounded-full"
            ></span><span class="sr-only">({tab.dot})</span>{/if}</a
        >
      </li>
    {/each}
  </ul>
  {#each [{ side: 'left', show: more.left, dir: -1 }, { side: 'right', show: more.right, dir: 1 }] as edge (edge.side)}
    {#if edge.show}
      <button
        type="button"
        tabindex="-1"
        aria-hidden="true"
        data-more={edge.side}
        onclick={() => scrollBy(edge.dir as 1 | -1)}
        class={cn(
          'text-muted-foreground absolute inset-y-0 flex w-9 items-center lg:hidden',
          edge.side === 'left'
            ? 'from-background left-0 justify-start bg-gradient-to-r to-transparent'
            : 'from-background right-0 justify-end bg-gradient-to-l to-transparent',
        )}
        ><span class={edge.side === 'left' ? 'rotate-180' : ''}
          ><NavIcon name="chevron" size={18} /></span
        ></button
      >
    {/if}
  {/each}
</nav>
