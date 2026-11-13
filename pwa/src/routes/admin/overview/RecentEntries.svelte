<script lang="ts" module>
  export interface RecentRow {
    id: string;
    formId: string;
    tenant?: string;
    formName: string;
    receivedAt: string | null;
    state: string;
    held: boolean;
  }
</script>

<script lang="ts">
  import { formatDateTime } from '$lib/format';
  import { t } from '$lib/i18n';
  import { router } from '$lib/router.svelte';
  import { formPath } from '$lib/routes';
  import { relativeTime } from '$lib/stats/series';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

  interface Props {
    tenant?: string;
    rows: RecentRow[];
    status: 'loading' | 'ready' | 'unavailable';
    /** Reference time for relative stamps (injectable for tests). */
    now?: number;
    /** Link target for "Alle ansehen" (first form's entries); omitted when unknown. */
    allFormId?: string;
    /** Link target for "Alle ansehen" when it is not a single form's entries. */
    allHref?: string;
  }
  let { tenant = '', rows, status, now = Date.now(), allFormId, allHref }: Props = $props();
  const ui = t.overview;
  const absolute = (iso: string | null): string => (iso ? formatDateTime(iso) : '');
  const target = (row: RecentRow): string => formPath(row.tenant ?? tenant, row.formId, 'entries');
  const go = (row: RecentRow): void => router.navigate(target(row));
</script>

<Panel title={ui.recent} description={ui.recentIntro} id="recent-entries">
  {#snippet actions()}
    {#if allFormId || allHref}
      {@const all = allHref ?? formPath(tenant, allFormId ?? '', 'entries')}<a
        class="text-brand-ink rounded-md px-1 text-sm font-medium underline underline-offset-4"
        href={all}
        onclick={(e) => {
          e.preventDefault();
          router.navigate(all);
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
          <li
            class="hover:bg-muted/50 focus-within:bg-muted/50 relative -mx-2 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-md px-2 py-2.5"
          >
            <span class="min-w-24 font-medium">{row.formName}</span>
            <time
              class="text-muted-foreground min-w-28 text-sm"
              datetime={row.receivedAt ?? undefined}
              title={absolute(row.receivedAt)}>{when ?? '–'}</time
            >
            <StatusChip tone="ok" label={row.state === 'accepted' ? ui.stateAccepted : row.state} />
            {#if row.held}<StatusChip tone="info" label={ui.protectedEntry} />{/if}
            <a
              class="text-muted-foreground focus-visible:ring-ring ml-auto inline-flex items-center rounded-md after:absolute after:inset-0 after:content-[''] focus-visible:ring-2 focus-visible:outline-none"
              href={target(row)}
              aria-label={ui.openEntry
                .replace('{form}', row.formName)
                .replace('{time}', when ?? '–')}
              onclick={(e) => {
                e.preventDefault();
                go(row);
              }}><NavIcon name="chevron" size={18} /></a
            >
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</Panel>
