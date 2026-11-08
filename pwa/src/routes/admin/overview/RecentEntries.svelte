<script lang="ts" module>
  export interface RecentRow {
    id: string;
    formId: string;
    formName: string;
    receivedAt: string | null;
    state: string;
    held: boolean;
  }
</script>

<script lang="ts">
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { relativeTime } from '$lib/stats/series';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';

  interface Props {
    tenant: string;
    rows: RecentRow[];
    status: 'loading' | 'ready' | 'unavailable';
    /** Reference time for relative stamps (injectable for tests). */
    now?: number;
    /** Link target for "Alle ansehen" (first form's entries); omitted when unknown. */
    allFormId?: string;
  }
  let { tenant, rows, status, now = Date.now(), allFormId }: Props = $props();
  const ui = t.overview;
  const absolute = (iso: string | null): string => {
    const ms = iso ? Date.parse(iso) : NaN;
    return Number.isNaN(ms)
      ? ''
      : new Intl.DateTimeFormat('de-DE', { dateStyle: 'medium', timeStyle: 'short' }).format(ms);
  };
  const go = (row: RecentRow): void => router.navigate(formPath(tenant, row.formId, 'entries'));
</script>

<Panel title={ui.recent} description={ui.recentIntro} id="recent-entries">
  {#snippet actions()}
    {#if allFormId}<a
        class="text-brand-ink rounded-md px-1 text-sm font-medium underline underline-offset-4"
        href={formPath(tenant, allFormId, 'entries')}
        onclick={(e) => {
          e.preventDefault();
          router.navigate(formPath(tenant, allFormId, 'entries'));
        }}>{ui.recentAll}</a
      >{/if}
  {/snippet}
  <div aria-busy={status === 'loading'}>
    {#if status === 'loading'}
      <div class="flex flex-col gap-3" aria-hidden="true">
        {#each [1, 2, 3] as n (n)}<Skeleton class="h-6 w-full" />{/each}
      </div>
    {:else if status === 'unavailable'}
      <p class="text-muted-foreground">{ui.recentUnavailable}</p>
    {:else if rows.length === 0}
      <p class="text-muted-foreground">{ui.recentNone}</p>
    {:else}
      <ul class="divide-border flex flex-col divide-y">
        {#each rows as row (`${row.formId}:${row.id}`)}
          {@const when = relativeTime(row.receivedAt, now)}
          <li class="flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5 first:pt-0 last:pb-0">
            <span class="min-w-24 font-medium">{row.formName}</span>
            <time
              class="text-muted-foreground min-w-28 text-sm"
              datetime={row.receivedAt ?? undefined}
              title={absolute(row.receivedAt)}>{when ?? '–'}</time
            >
            <StatusChip tone="ok" label={row.state === 'accepted' ? ui.stateAccepted : row.state} />
            {#if row.held}<StatusChip tone="info" label={ui.protectedEntry} />{/if}
            <a
              class="text-brand-ink ml-auto rounded-md px-1 text-sm font-medium underline underline-offset-4"
              href={formPath(tenant, row.formId, 'entries')}
              aria-label={ui.openEntry
                .replace('{form}', row.formName)
                .replace('{time}', when ?? '–')}
              onclick={(e) => {
                e.preventDefault();
                go(row);
              }}>{ui.open} ›</a
            >
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</Panel>
