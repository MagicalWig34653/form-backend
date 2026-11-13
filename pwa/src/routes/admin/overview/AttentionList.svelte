<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { formPath, type Tab } from '$lib/routes';
  import type { AttentionItem } from '$lib/stats/overview';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import { Button } from '$lib/components/ui/button';

  interface Props {
    tenant?: string;
    items: AttentionItem[];
    loading?: boolean;
    /** Some data is still missing: hints may follow. */
    partial?: boolean;
  }
  let { tenant = '', items, loading = false, partial = false }: Props = $props();

  const LIMIT = 3;
  let showAll = $state(false);
  const shown = $derived(showAll ? items : items.slice(0, LIMIT));
  const ui = t.overview;
  const copy: Record<AttentionItem['kind'], { text: string; action?: string; tab: Tab }> = {
    locked: { text: ui.locked, action: ui.lockedAction, tab: 'overview' },
    noMail: { text: ui.noMail, action: ui.noMailAction, tab: 'mail' },
    unpublished: { text: ui.unpublished, action: ui.unpublishedAction, tab: 'publish' },
    inactive: { text: ui.inactive, action: ui.inactiveAction, tab: 'overview' },
    quiet: { text: ui.quiet, action: ui.quietAction, tab: 'publish' },
  };
  const textOf = (item: AttentionItem): string =>
    copy[item.kind].text.replace('{form}', item.formName ?? '');
  function open(item: AttentionItem): void {
    if (item.kind === 'locked') return router.navigate('/account');
    if (item.formId)
      router.navigate(formPath(item.tenant ?? tenant, item.formId, copy[item.kind].tab));
  }
</script>

<Panel title={ui.attention} id="attention">
  <div aria-busy={loading}>
    {#if loading}
      <div class="flex flex-col gap-3" aria-hidden="true">
        <Skeleton class="h-5 w-3/4" /><Skeleton class="h-5 w-2/3" />
      </div>
    {:else}
      {#if items.length > 0}
        <ul class="divide-border flex flex-col divide-y">
          {#each shown as item (item.id)}
            <li
              class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 py-2.5 first:pt-0"
            >
              <span class="flex min-w-0 flex-1 basis-56 items-start gap-2.5">
                <span
                  aria-hidden="true"
                  class={item.tone === 'warn'
                    ? 'text-amber-800 dark:text-amber-400 mt-0.5'
                    : 'text-blue-700 dark:text-blue-400 mt-0.5'}
                  ><NavIcon name={item.tone === 'warn' ? 'warn' : 'info'} size={18} /></span
                >
                <span class=" leading-6">{textOf(item)}</span>
              </span>
              {#if copy[item.kind].action && (item.formId || item.kind === 'locked')}
                <Button variant="outline" onclick={() => open(item)}
                  >{copy[item.kind].action}{#if item.formName}<span class="sr-only"
                      >: {item.formName}</span
                    >{/if}</Button
                >
              {/if}
            </li>
          {/each}
        </ul>
        {#if items.length > LIMIT}
          <Button
            variant="ghost"
            class="mt-2"
            aria-expanded={showAll}
            onclick={() => (showAll = !showAll)}
            >{showAll
              ? ui.attentionLess
              : ui.attentionMore.replace('{n}', String(items.length - LIMIT))}</Button
          >
        {/if}
      {:else}
        <p class="text-muted-foreground">{ui.attentionNone}</p>
      {/if}
      {#if partial}<p class="text-muted-foreground mt-2 text-sm">
          {ui.attentionPartial}
        </p>{/if}
    {/if}
  </div>
</Panel>
