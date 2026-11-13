<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import Banner from './Banner.svelte';
  import type { Need } from '$lib/components/shell/nav';

  interface Props {
    /** Which needs this page can explain; others are ignored. */
    accepts: readonly Need[];
    /** Called once when the hint appears, e.g. to move focus to the list. */
    onshown?: () => void;
  }
  let { accepts, onshown }: Props = $props();

  const need = $derived.by((): Need | null => {
    const raw = new URLSearchParams(router.search).get('need');
    return raw && (accepts as readonly string[]).includes(raw) ? (raw as Need) : null;
  });
  const text: Record<Need, string> = {
    customer: t.shell.needCustomer,
    entries: t.shell.needEntries,
    statistics: t.shell.needStatistics,
  };
  $effect(() => {
    if (need) onshown?.();
  });
</script>

{#if need}
  <Banner
    tone="info"
    title={need === 'customer' ? t.shell.needCustomerTitle : t.shell.needFormTitle}
  >
    <span data-testid="need-hint">{text[need]}</span>
  </Banner>
{/if}
