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

  interface Props {
    /** Accessible name of the tab navigation. */
    label: string;
    tabs: PageTab[];
    class?: string;
  }
  let { label, tabs, class: className }: Props = $props();
  let list = $state<HTMLElement | null>(null);

  function go(event: MouseEvent, href: string): void {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    router.navigate(href);
  }
  // Tabs scroll sideways on narrow screens; the current one is brought into view after navigation.
  $effect(() => {
    void tabs.map((x) => x.active).join();
    void tick().then(() =>
      list
        ?.querySelector('[aria-current="page"]')
        ?.scrollIntoView?.({ inline: 'nearest', block: 'nearest' }),
    );
  });
</script>

<nav aria-label={label} class={cn('border-border -mb-px min-w-0 border-b', className)}>
  <ul bind:this={list} class="m-0 flex list-none gap-1 overflow-x-auto p-0 pb-px">
    {#each tabs as tab (tab.id)}
      <li class="shrink-0">
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
</nav>
