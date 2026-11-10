<script lang="ts">
  import type { Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import { cn } from '$lib/utils';
  import { Button } from '$lib/components/ui/button';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    /** Accessible name of the filter group. */
    label?: string;
    /** Number of active filters: drives the badge on mobile and the reset button. */
    activeCount?: number;
    /** Called by the reset button (shown while a filter is active). */
    onreset?: () => void;
    /** Below the sm breakpoint the fields sit behind a "Filter" toggle (default). */
    collapsible?: boolean;
    /** Explanation below the fields. */
    hint?: string;
    /** Extra controls at the end of the row, e.g. a search button. */
    trailing?: Snippet;
    children?: Snippet;
    class?: string;
  }
  let {
    label = t.listUi.filter,
    activeCount = 0,
    onreset,
    collapsible = true,
    hint,
    trailing,
    children,
    class: className,
  }: Props = $props();
  let open = $state(false);
  const id = $props.id();
</script>

<div role="group" aria-label={label} class={cn('flex flex-col gap-3', className)}>
  {#if collapsible}
    <button
      type="button"
      class=" bg-card ring-1 ring-foreground/10 rounded-xl flex min-h-10 items-center justify-between gap-2 px-3 text-sm font-medium sm:hidden"
      aria-expanded={open}
      aria-controls={`${id}-fields`}
      onclick={() => (open = !open)}
    >
      <span class="flex items-center gap-2"
        ><NavIcon name="settings" size={16} /><span>{t.listUi.filter}</span></span
      >
      {#if activeCount > 0}<span
          class="bg-primary text-primary-foreground rounded-full px-2 text-sm leading-5"
          ><span class="sr-only">{t.listUi.filterActiveLabel} </span>{activeCount}</span
        >{/if}
    </button>
  {/if}
  <div
    id={`${id}-fields`}
    class={cn(
      'flex-wrap items-end gap-x-3 gap-y-3',
      collapsible && !open ? 'hidden sm:flex' : 'flex',
    )}
  >
    {@render children?.()}
    {#if trailing || (onreset && activeCount > 0)}
      <div class="flex max-w-full flex-wrap items-end gap-2">
        {@render trailing?.()}
        {#if onreset && activeCount > 0}
          <Button type="button" variant="ghost" onclick={onreset}>{t.listUi.filterClear}</Button>
        {/if}
      </div>
    {/if}
  </div>
  {#if hint}<p class="text-muted-foreground text-sm leading-[18px]">
      {hint}
    </p>{/if}
</div>
