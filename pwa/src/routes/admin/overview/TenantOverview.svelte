<script lang="ts">
  import { t } from '$lib/i18n';
  import type { FormListItem } from '$lib/api/admin';
  import type { OverviewLoader } from '$lib/stats/loader.svelte';
  import {
    aggregate,
    combinedStatus,
    deriveAttention,
    emptySnapshot,
    setupSteps,
  } from '$lib/stats/overview';
  import {
    conversion,
    conversionSeries,
    conversionWeeks,
    total,
    weekOverWeek,
    type Series,
  } from '$lib/stats/series';
  import { Button } from '$lib/components/ui/button';
  import KpiTile, { type TileDelta } from './KpiTile.svelte';
  import AttentionList from './AttentionList.svelte';
  import SetupProgress from './SetupProgress.svelte';
  import RecentEntries, { type RecentRow } from './RecentEntries.svelte';

  interface Props {
    tenant: string;
    forms: FormListItem[];
    loader: OverviewLoader;
    /** Access to submissions is locked in this browser. */
    locked?: boolean;
    /** More forms exist than are loaded. */
    moreForms?: boolean;
    onreload?: () => void;
  }
  let { tenant, forms, loader, locked = false, moreForms = false, onreload }: Props = $props();

  const ui = t.overview;
  const snaps = $derived(forms.map((f) => loader.snapshots.get(f.id) ?? emptySnapshot()));
  const statsState = $derived(combinedStatus(snaps.map((s) => s.statsStatus)));
  const entriesState = $derived(combinedStatus(snaps.map((s) => s.entriesStatus)));
  const detailState = $derived(combinedStatus(snaps.map((s) => s.detailStatus)));
  const anyLoading = $derived(
    snaps.some(
      (s) =>
        s.statsStatus === 'loading' ||
        s.detailStatus === 'loading' ||
        s.entriesStatus === 'loading',
    ),
  );
  const anyError = $derived(
    snaps.some(
      (s) => s.statsStatus === 'error' || s.detailStatus === 'error' || s.entriesStatus === 'error',
    ),
  );
  let stamp = $state<Date | null>(null);
  $effect(() => {
    if (!anyLoading && forms.length > 0) stamp = new Date();
  });

  const visits = $derived(aggregate(snaps, 'visits'));
  const submits = $derived(aggregate(snaps, 'submits'));
  const tileStatus = $derived(
    statsState.status === 'ready'
      ? 'ready'
      : statsState.status === 'loading'
        ? 'loading'
        : 'unavailable',
  );

  const fmtSigned = new Intl.NumberFormat('de-DE', {
    signDisplay: 'exceptZero',
    maximumFractionDigits: 0,
  });
  const fmtPoints = new Intl.NumberFormat('de-DE', {
    signDisplay: 'exceptZero',
    maximumFractionDigits: 1,
  });
  const fmtPercent = (n: number): string =>
    new Intl.NumberFormat('de-DE', { style: 'percent', maximumFractionDigits: 1 }).format(n);

  function countDelta(pair: { current: number; previous: number } | null): TileDelta | null {
    if (!pair) return null;
    const d = pair.current - pair.previous;
    return d === 0
      ? { direction: 'flat', text: ui.unchanged }
      : { direction: d > 0 ? 'up' : 'down', text: `${fmtSigned.format(d)} ${ui.vsWeek}` };
  }
  function pointsDelta(pair: { current: number; previous: number } | null): TileDelta | null {
    if (!pair) return null;
    const d = Math.round((pair.current - pair.previous) * 1000) / 10;
    return d === 0
      ? { direction: 'flat', text: ui.unchanged }
      : { direction: d > 0 ? 'up' : 'down', text: `${fmtPoints.format(d)} ${ui.vsWeekPoints}` };
  }
  const describe = (metric: string, series: Series | null): string =>
    ui.sparkLabel
      .replace('{metric}', metric)
      .replace('{values}', (series ?? []).map((v) => (v === null ? '–' : String(v))).join(', '));

  const submitsTotal = $derived(submits ? total(submits) : null);
  const visitsTotal = $derived(visits ? total(visits) : null);
  const convSeries = $derived(visits && submits ? conversionSeries(visits, submits) : null);
  const convValue = $derived(conversion(visitsTotal, submitsTotal));
  const activeCount = $derived(forms.filter((f) => f.active && f.currentReleaseId).length);

  const scope = $derived(
    statsState.ready < statsState.total && statsState.status === 'ready'
      ? ui.scopePartial
          .replace('{ready}', String(statsState.ready))
          .replace('{total}', String(statsState.total))
      : ui.scope.replace('{n}', String(forms.length)),
  );

  const byId = $derived(new Map(forms.map((f) => [f.id, f])));
  const recent = $derived<RecentRow[]>(
    forms
      .flatMap((f) => (loader.snapshots.get(f.id)?.entries ?? []).map((e) => ({ f, e })))
      .sort((a, b) => Date.parse(b.e.receivedAt ?? '') - Date.parse(a.e.receivedAt ?? '') || 0)
      .slice(0, 6)
      .map(({ f, e }) => ({
        id: e.id,
        formId: f.id,
        formName: byId.get(f.id)?.name ?? f.name,
        receivedAt: e.receivedAt,
        state: e.state,
        held: e.held,
      })),
  );
  const recentStatus = $derived(
    entriesState.status === 'ready'
      ? 'ready'
      : entriesState.status === 'loading'
        ? 'loading'
        : 'unavailable',
  );

  const attention = $derived(deriveAttention(forms, loader.snapshots, locked));
  const steps = $derived(setupSteps(forms, loader.snapshots));
  const timeText = $derived(
    stamp ? new Intl.DateTimeFormat('de-DE', { timeStyle: 'short' }).format(stamp) : '…',
  );
</script>

<div class="flex min-w-0 flex-col gap-4">
  <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
    <p class="text-muted-foreground text-sm">
      {ui.subtitle.replace('{time}', timeText)}
      <span class="block sm:ml-2 sm:inline">· {scope}{moreForms ? ` · ${ui.scopeMore}` : ''}</span>
    </p>
    {#if anyError && !anyLoading && onreload}<Button variant="outline" onclick={onreload}
        >{ui.retryAll}</Button
      >{/if}
  </div>

  <div class="tile-grid" data-testid="kpi-grid">
    <div data-w="3">
      <KpiTile
        index={0}
        label={ui.kpiSubmits}
        hint={ui.hintSubmits}
        status={tileStatus}
        value={submitsTotal}
        series={submits}
        seriesLabel={describe(ui.kpiSubmits, submits)}
        delta={submits ? countDelta(weekOverWeek(submits)) : null}
      />
    </div>
    <div data-w="3">
      <KpiTile
        index={1}
        label={ui.kpiVisits}
        hint={ui.hintVisits}
        status={tileStatus}
        value={visitsTotal}
        series={visits}
        seriesLabel={describe(ui.kpiVisits, visits)}
        delta={visits ? countDelta(weekOverWeek(visits)) : null}
      />
    </div>
    <div data-w="3">
      <KpiTile
        index={2}
        label={ui.kpiConversion}
        hint={ui.hintConversion}
        status={tileStatus}
        value={convValue}
        format={fmtPercent}
        series={convSeries}
        seriesLabel={describe(ui.kpiConversion, convSeries)}
        delta={visits && submits ? pointsDelta(conversionWeeks(visits, submits)) : null}
        reason={tileStatus === 'ready' ? ui.noConversion : undefined}
      />
    </div>
    <div data-w="3">
      <KpiTile
        index={3}
        label={ui.kpiActive}
        hint={ui.hintActive}
        value={activeCount}
        note={ui.activeOf.replace('{n}', String(forms.length))}
      />
    </div>
  </div>

  <div class="tile-grid">
    <div data-w="6">
      <AttentionList
        {tenant}
        items={attention}
        partial={anyLoading || detailState.status === 'error'}
      />
    </div>
    <div data-w="6">
      <SetupProgress {tenant} {steps} loading={anyLoading && detailState.status === 'loading'} />
    </div>
  </div>

  <div>
    <RecentEntries
      {tenant}
      rows={recent}
      status={recentStatus}
      allFormId={forms.length === 1 ? forms[0]?.id : undefined}
    />
  </div>
</div>
