<script lang="ts">
  import { formatClock } from '$lib/format';
  import { t } from '$lib/i18n';
  import type { OverviewLoader } from '$lib/stats/loader.svelte';
  import {
    aggregate,
    combinedStatus,
    deriveAttention,
    emptySnapshot,
    setupSteps,
    type ScopedForm,
  } from '$lib/stats/overview';
  import {
    conversion,
    conversionSeries,
    conversionWeeks,
    total,
    weekOverWeek,
    type Series,
  } from '$lib/stats/series';
  import { countDelta, formatPercent, pointsDelta } from '$lib/stats/delta';
  import { Button } from '$lib/components/ui/button';
  import KpiTile from './KpiTile.svelte';
  import AttentionList from './AttentionList.svelte';
  import SetupProgress from './SetupProgress.svelte';
  import RecentEntries, { type RecentRow } from './RecentEntries.svelte';

  interface Props {
    /** Customer of all forms; omitted on the overall dashboard where each form carries its own. */
    tenant?: string;
    forms: ScopedForm[];
    loader: OverviewLoader;
    /** Access to submissions is locked in this browser. */
    locked?: boolean;
    /** More forms exist than are loaded. */
    moreForms?: boolean;
    onreload?: () => void;
    /** Customer-wide setup progress; not meaningful over several customers. */
    showSetup?: boolean;
    recentLimit?: number;
    /** Target of "Alle ansehen" instead of the single form's entries. */
    allHref?: string;
    /** Leading text of the section subtitle, e.g. "2 Kunden, 2 Formulare". */
    lead?: string;
  }
  let {
    tenant = '',
    forms,
    loader,
    locked = false,
    moreForms = false,
    onreload,
    showSetup = true,
    recentLimit = 6,
    allHref,
    lead,
  }: Props = $props();

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

  const fmtPercent = formatPercent;
  const describe = (metric: string, series: Series | null): string =>
    ui.sparkLabel
      .replace('{metric}', metric)
      .replace('{values}', (series ?? []).map((v) => (v === null ? '–' : String(v))).join(', '));

  const submitsTotal = $derived(submits ? total(submits) : null);
  const visitsTotal = $derived(visits ? total(visits) : null);
  const convValue = $derived(conversion(visitsTotal, submitsTotal));
  const activeCount = $derived(forms.filter((f) => f.active && f.currentReleaseId).length);
  const convSeries = $derived(visits && submits ? conversionSeries(visits, submits) : undefined);
  const formNames = $derived(Object.fromEntries(forms.map((f) => [f.id, f.name])));

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
      .slice(0, recentLimit)
      .map(({ f, e }) => ({
        id: e.id,
        formId: f.id,
        ...(f.tenant ? { tenant: f.tenant } : {}),
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
  // The setup panel already names the next missing step; the missing-route hints are not repeated per form above it.
  const attentionShown = $derived(
    showSetup ? attention.filter((x) => x.kind !== 'noMail') : attention,
  );
  const steps = $derived(setupSteps(forms, loader.snapshots));
  const timeText = $derived(stamp ? formatClock(stamp) : '…');
</script>

<div class="flex min-w-0 flex-col gap-4">
  <div class="flex flex-wrap items-end justify-between gap-x-4 gap-y-1">
    <div>
      <h2 class="m-0 text-xl leading-snug font-semibold tracking-tight">{ui.kpiSection}</h2>
      <p class="text-muted-foreground m-0 mt-0.5 text-sm leading-5" title={scope}>
        {lead ? `${lead} · ` : ''}{ui.subtitle.replace('{time}', timeText)}{statsState.ready <
          statsState.total && statsState.status === 'ready'
          ? ` · ${scope}`
          : ''}{moreForms ? ` · ${ui.scopeMore}` : ''}
      </p>
    </div>
    {#if anyError && !anyLoading && onreload}<Button variant="outline" onclick={onreload}
        >{ui.retryAll}</Button
      >{/if}
  </div>

  <div class="tile-grid scroll-mt-20" data-testid="kpi-grid" id="statistics">
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
        seriesLabel={convSeries ? describe(ui.kpiConversion, convSeries) : ''}
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
        fraction={forms.length ? activeCount / forms.length : 0}
        note={ui.activeOf
          .replace('{active}', String(activeCount))
          .replace('{n}', String(forms.length))}
      />
    </div>
  </div>

  <div class="tile-grid">
    <div data-w={showSetup ? '6' : undefined}>
      <AttentionList
        {tenant}
        items={attentionShown}
        partial={anyLoading || detailState.status === 'error'}
      />
    </div>
    {#if showSetup}
      <div data-w="6">
        <SetupProgress
          {tenant}
          {steps}
          {formNames}
          loading={anyLoading && detailState.status === 'loading'}
        />
      </div>
    {/if}
  </div>

  <div>
    <RecentEntries
      {tenant}
      rows={recent}
      status={recentStatus}
      {allHref}
      allFormId={!allHref && forms.length === 1 ? forms[0]?.id : undefined}
    />
  </div>
</div>
