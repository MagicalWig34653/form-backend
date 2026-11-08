<script lang="ts" module>
  export interface Crumb {
    label: string;
    href?: string;
  }
</script>

<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { cn } from '$lib/utils';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    items: Crumb[];
    /** On narrow screens only the last segment is shown (the page title stays reachable). */
    collapseOnMobile?: boolean;
    class?: string;
  }
  let { items, collapseOnMobile = true, class: className }: Props = $props();

  function go(event: MouseEvent, href: string): void {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    router.navigate(href);
  }
</script>

{#if items.length > 0}
  <nav aria-label={t.ui.breadcrumbs} class={cn('min-w-0', className)}>
    <ol class="text-muted-foreground flex min-w-0 items-center text-sm">
      {#each items as item, i (i)}
        {@const last = i === items.length - 1}
        <li class={cn('flex min-w-0 items-center', collapseOnMobile && !last && 'hidden sm:flex')}>
          {#if i > 0}<span aria-hidden="true" class="mx-1.5 shrink-0 opacity-60"
              ><NavIcon name="chevron" size={12} /></span
            >{/if}
          {#if item.href && !last}
            <a
              href={item.href}
              onclick={(e) => go(e, item.href as string)}
              class="hover:text-foreground truncate rounded-sm underline-offset-4 hover:underline"
              >{item.label}</a
            >
          {:else}
            <span
              aria-current={last ? 'page' : undefined}
              class={cn('truncate', last && 'text-foreground font-medium')}>{item.label}</span
            >
          {/if}
        </li>
      {/each}
    </ol>
  </nav>
{/if}
