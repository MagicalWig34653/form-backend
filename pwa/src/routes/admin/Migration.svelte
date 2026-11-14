<script lang="ts">
  import { formatClock, formatDay } from '$lib/format';
  import { confirmAction } from '$lib/confirm.svelte';
  import { verifyMigrationProbe } from '$lib/crypto/migrationProbe';
  import { parseLegacyPrivateKey } from '$lib/crypto/legacyAdoption';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { onMount } from 'svelte';
  import { http, adminApi } from '$lib/api';
  import type { Tenant } from '$lib/api/admin';
  import { migrationStates } from '$lib/setup';
  import { reauthenticate, stepUp } from '$lib/admin/guard.svelte';
  import { needsFreshLogin } from '$lib/admin/describe';
  import {
    MIGRATION_STEPS,
    assignConnections,
    assignForms,
    assignKeys,
    buildPlan,
    snapshotOf,
    canAdvance,
    countRows,
    describeJobError,
    keyImportable,
    keyWarnings,
    mappingIssues,
    landingStep,
    reachedStep,
    reportRows,
    summarizeReport,
    sourceConnections,
    sourceForms,
    suggestNamespace,
    type PlanCustomer,
    type SourceInventory,
  } from '$lib/admin/migrationFlow';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Stepper from '$lib/components/admin/Stepper.svelte';
  import StepNav from '$lib/components/admin/StepNav.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';
  import StatusChip, { type Tone } from '$lib/components/admin/StatusChip.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  interface Job {
    formIds?: string[];
    probeConfirmed?: boolean;
    testConfirmed?: boolean;
    /** Server: false when the import holds no :2 package, so no decryption probe is possible or required (finding B). */
    probeRequired?: boolean;
    id: string;
    state: string;
    phase: string;
    dryRun: boolean;
    error: string;
    report: Record<string, unknown>;
  }
  let host = $state(''),
    port = $state(3306),
    database = $state(''),
    username = $state(''),
    password = $state(''),
    tls = $state('verify');
  let tenants = $state<Tenant[]>([]);
  let inventory = $state<SourceInventory>();
  // Plan state: customers are the only manual input; everything else is derived from the source check.
  let customers = $state<PlanCustomer[]>([]);
  let formChoice = $state<Record<string, string>>({}),
    connectionChoice = $state<Record<string, string>>({}),
    keyChoice = $state<Record<string, string>>({});
  let namespace = $state(''),
    suggestedNamespace = '',
    snapshot = $state(''),
    checkedSource = $state('');
  let expectedSchema = $state(''),
    checkedSchema = $state(''),
    extra = $state('{}');
  let jobs = $state<Job[]>([]),
    error = $state(''),
    notice = $state(''),
    busy = $state(false),
    updated = $state(''),
    loaded = $state(false);
  let activeSecret: Uint8Array | undefined;
  let privateKey = $state('');
  let probe = $state<{ wire: string; hash: string; jobId: string }>();
  let step = $state(0);
  let prevReached = -1;
  // The legacy data changed (before or during the import): a plain resume would fail again, only a new rehearsal or a restore helps.
  const quiesceErrors = ['source_changed', 'source_not_quiesced', 'snapshot_changed'];
  const ui = t.formKit.migration;
  const f = ui.flow;
  const stepList = [
    { id: 'source', label: ui.steps.source },
    { id: 'mapping', label: ui.steps.mapping },
    { id: 'import', label: ui.steps.import },
    { id: 'review', label: ui.steps.review },
    { id: 'switch', label: ui.steps.switch },
  ];
  const stateTones: Record<string, Tone> = {
    queued: 'idle',
    running: 'info',
    paused: 'warn',
    failed: 'danger',
    review: 'warn',
    closed: 'ok',
  };
  /** Furthest phase the real job data justifies; never invented. */
  const reached = $derived(reachedStep(jobs, !!checkedSchema));
  const landing = $derived(landingStep(jobs, !!checkedSchema));
  const overall = $derived.by((): { tone: Tone; label: string } => {
    const job = jobs[0];
    if (!job) return { tone: 'idle', label: ui.none };
    return {
      tone: stateTones[job.state] ?? 'idle',
      label: migrationStates[job.state] ?? job.state,
    };
  });
  // Jobs move the guided flow on by themselves (running import, review, closed); a mere source
  // check keeps the report visible until the user presses "Weiter".
  $effect(() => {
    const now = landing;
    if (!loaded) return;
    if (prevReached === -1 || (now > prevReached && now >= 2)) step = now;
    prevReached = now;
  });
  const source = () => ({ host, port, database, username, password, tls });
  /** Connection identity without the password: a change after the check invalidates the plan. */
  const sourceKey = () => JSON.stringify([host, port, database, username, tls]);
  const sourceChanged = $derived(!!checkedSource && sourceKey() !== checkedSource);
  const forms = $derived(sourceForms(inventory));
  const connections = $derived(sourceConnections(inventory));
  const keys = $derived(inventory?.keys ?? []);
  const usage = $derived(inventory?.keyUsage?.items ?? []);
  const formCustomers = $derived(
    assignForms(
      forms.map((form) => form.id),
      customers,
      formChoice,
    ),
  );
  const built = $derived(
    buildPlan({
      namespace,
      snapshot,
      customers,
      formCustomers,
      connectionCustomers: assignConnections(
        connections,
        forms,
        formCustomers,
        customers,
        connectionChoice,
      ),
      keys,
      keyCustomers: assignKeys(keys, usage, formCustomers, customers, keyChoice),
      extra,
    }),
  );
  const issues = $derived(
    mappingIssues({
      ...built,
      formIds: forms.map((form) => form.id),
      connectionIds: connections.map((c) => c.id),
      keys,
      expectedSchema,
      sourceChanged,
    }),
  );
  const warnings = $derived(keyWarnings(keys, usage, built.plan));
  /** Statistics rows need public recipient keys in the plan; without them every row becomes a review case. */
  const statsRows = $derived(
    Object.keys(built.plan.statisticsPublicKeys).length ? 0 : (inventory?.counts?.statistics ?? 0),
  );
  const usageOf = (kid: string) => usage.find((u) => u.kid === kid)?.submissions ?? 0;
  const customerName = (id: string | undefined) => {
    const index = customers.findIndex((c) => c.id === id);
    return index < 0
      ? ''
      : customers[index]!.name.trim() || f.mapping.customerN.replace('{n}', String(index + 1));
  };
  const label = (name: string | null) => name ?? f.mapping.unnamed;
  const closedJob = $derived(jobs[0]?.state === 'closed' ? jobs[0] : undefined);
  /** Key id of the probe sample (`KUBUS-AEAD:2|<kid>|hpke|...`); a public identifier, not a secret. */
  const probeKid = $derived(probe?.wire.split('|')[1] ?? '');
  const importJob = $derived(jobs.find((job) => job.state === 'review' && !job.dryRun));
  const noProbe = $derived(importJob?.probeRequired === false);
  /** The import creates the customer on the server; the session list (loaded at login) must learn it, or Account, Advanced offers no
   *  field to adopt the old key (QA finding 7B5E1E8A). Once per import job. */
  let tenantsRefreshedFor = '';
  $effect(() => {
    const id = importJob?.id;
    if (!id || id === tenantsRefreshedFor) return;
    tenantsRefreshedFor = id;
    void session.refreshTenants();
  });
  /** Submissions kept in review because their package is not :2 (count from the report issues). */
  const legacyKept = $derived(
    (importJob?.report?.issues as { code: string; count: number }[] | undefined)?.find(
      (issue) => issue.code === 'unsupported-content',
    )?.count ?? 0,
  );
  let withoutProbeOk = $state(false);
  const removeMissing = $derived(
    noProbe
      ? []
      : [
          importJob?.probeConfirmed ? '' : f.done.missingProbe,
          importJob?.testConfirmed ? '' : f.done.missingTest,
        ].filter(Boolean),
  );
  const goBack = () => (step = Math.max(0, step - 1));
  const goNext = () => {
    if (canAdvance(step, reached)) step += 1;
  };
  async function request<T>(
    method: 'GET' | 'POST',
    path: string,
    body?: unknown,
    unprocessable?: string,
  ): Promise<T | undefined> {
    const r = await http.request<T>(method, path, { body });
    if (r.ok) return r.data;
    if (needsFreshLogin(r.error)) {
      await reauthenticate('/migration');
      return;
    }
    error =
      r.error.status === 403
        ? f.noRight
        : r.error.status === 429
          ? f.busy
          : r.error.status === 409
            ? r.error.code === 'already_imported'
              ? f.alreadyImported
              : f.conflict
            : r.error.status === 422 && r.error.detail
              ? r.error.detail
              : r.error.status === 422 && unprocessable
                ? unprocessable
                : f.connection;
  }
  async function load() {
    if (!tenants.length) {
      const t = await adminApi.tenants();
      if (t.ok) tenants = t.data.items;
    }
    const r = await request<{ items: Job[] }>('GET', '/migration/jobs');
    if (r) {
      jobs = r.items;
      updated = formatClock(new Date());
    }
    loaded = true;
  }
  onMount(() => {
    void load();
    // No background poll while the passkey dialog is open or after it was cancelled (no dialog spam, ADR 0037).
    const timer = setInterval(() => {
      if (!stepUp.open && !stepUp.suppressed) void load();
    }, 3000);
    return () => {
      clearInterval(timer);
      password = '';
      privateKey = '';
      activeSecret?.fill(0);
      probe = undefined;
    };
  });
  /**
   * Takes everything derivable from the source check, on every check: schema HMAC, snapshot id
   * and namespace proposal (the namespace only while the user kept the previous proposal). The
   * first customer gets a fresh id; names stay manual because the old system has none.
   */
  async function prefill(r: SourceInventory) {
    if (!customers.length) customers = [{ id: crypto.randomUUID(), name: '' }];
    expectedSchema = r.schemaHMAC;
    snapshot = await snapshotOf(r);
    const proposal = suggestNamespace(host, database);
    if (!namespace.trim() || namespace === suggestedNamespace) namespace = proposal;
    suggestedNamespace = proposal;
  }
  async function test() {
    busy = true;
    error = '';
    checkedSchema = '';
    const r = await request<SourceInventory>('POST', '/migration/test', source());
    if (r) {
      checkedSchema = r.schemaHMAC;
      checkedSource = sourceKey();
      inventory = r;
      await prefill(r);
    }
    busy = false;
  }
  async function start() {
    if (issues.length) return;
    busy = true;
    error = '';
    const created = await request(
      'POST',
      '/migration/jobs',
      { source: source(), plan: built.plan, expectedSchema, dryRun: true },
      f.mapping.startRejected,
    );
    if (created) password = '';
    await load();
    busy = false;
  }
  function setCustomer(index: number, tenantId: string) {
    const selected = tenants.find((tenant) => tenant.id === tenantId);
    customers[index] = selected
      ? { id: selected.id, name: selected.name }
      : { id: crypto.randomUUID(), name: '' };
  }
  async function action(id: string, action: string) {
    error = '';
    await request('POST', `/migration/jobs/${id}/${action}`);
    await load();
  }
  let released = $state<{ released: number; kept: number }>();
  async function releaseSubmissions(job: Job) {
    error = '';
    notice = '';
    released = undefined;
    busy = true;
    const r = await request<{ released: number; kept: number }>(
      'POST',
      `/migration/jobs/${job.id}/release-submissions`,
    );
    busy = false;
    if (r) released = { released: r.released, kept: r.kept };
    await load();
  }
  async function getProbe(job: Job) {
    error = '';
    privateKey = '';
    probe = undefined;
    const r = await request<{ wire: string; hash: string }>(
      'GET',
      `/migration/jobs/${job.id}/probe`,
    );
    if (r) probe = { ...r, jobId: job.id };
    else if (job.probeRequired === false) error = f.review.probeNone;
  }
  async function verifyProbe() {
    if (!probe) return;
    const selected = probe;
    let secret: Uint8Array | undefined;
    busy = true;
    error = '';
    notice = '';
    try {
      const text = privateKey;
      privateKey = '';
      secret = parseLegacyPrivateKey(text);
      activeSecret = secret;
      const testHash = await verifyMigrationProbe(
        selected.wire,
        selected.hash,
        secret,
        async (hash) => {
          if (
            !(await confirmAction({
              title: t.confirm.probeTitle,
              description: t.confirm.probeBody,
              confirmLabel: t.confirm.probe,
            }))
          )
            throw new Error('cancelled');
          if (
            !(await request('POST', `/migration/jobs/${selected.jobId}/verify`, {
              hash,
              success: true,
            }))
          )
            throw new Error('request');
        },
      );
      if (
        await request('POST', `/migration/jobs/${selected.jobId}/verify`, {
          hash: selected.hash,
          success: true,
          testHash,
        })
      ) {
        notice = f.msg.probeOk;
        probe = undefined;
      }
    } catch {
      error = f.msg.probeFailed;
    } finally {
      secret?.fill(0);
      activeSecret = undefined;
      privateKey = '';
      busy = false;
    }
  }
  async function convert(job: Job) {
    error = '';
    notice = '';
    for (const id of job.formIds ?? []) {
      if (!/^[0-9a-f-]{36}$/.test(id)) {
        error = f.msg.formUuid;
        return;
      }
      if (!(await request('POST', `/migration/legacy-forms/${id}/draft`))) return;
    }
    notice = f.msg.drafts;
  }
  function download(job: Job) {
    const url = URL.createObjectURL(
      new Blob([JSON.stringify(job.report, null, 2)], { type: 'application/json' }),
    );
    const a = document.createElement('a');
    a.href = url;
    a.download = `umstieg-${job.id}.json`;
    a.click();
    URL.revokeObjectURL(url);
  }
  const rowClass = 'flex flex-wrap items-baseline justify-between gap-x-4 gap-y-0.5 py-1.5 text-sm';
</script>

{#snippet report(job: Job)}
  {@const rows = reportRows(job.report)}
  {@const sum = summarizeReport(job.report)}
  {#if sum.processed !== null && !sum.tables.length}
    <p class="m-0 flex justify-between gap-2 text-sm" data-testid="migration-processed">
      <span class="text-muted-foreground">{f.run.processed}</span>
      <span class="font-medium tabular-nums">{sum.processed}</span>
    </p>
  {:else if sum.tables.length}
    <div class="flex min-w-0 flex-col gap-4" data-testid="migration-report">
      <!-- svelte-ignore a11y_no_noninteractive_tabindex (scrollable region must be keyboard focusable, axe) -->
      <div class="overflow-x-auto" role="region" aria-label={f.run.tablesCaption} tabindex="0">
        <table class="w-full text-left text-xs sm:text-sm">
          <caption class="sr-only">{f.run.tablesCaption}</caption>
          <thead>
            <tr class="text-muted-foreground">
              <th scope="col" class="py-1 pr-2 font-medium">{f.run.colTable}</th>
              <th scope="col" class="px-1 py-1 text-right font-medium">{f.run.colSource}</th>
              <th scope="col" class="px-1 py-1 text-right font-medium">{f.run.colImported}</th>
              <th scope="col" class="px-1 py-1 text-right font-medium">{f.run.colReview}</th>
            </tr>
          </thead>
          <tbody class="divide-border divide-y">
            {#each sum.tables as row (row.table)}
              <tr>
                <th scope="row" class="py-1 pr-2 font-normal">
                  {f.run.tableNames[row.table] ?? row.table}
                </th>
                <td class="px-1 py-1 text-right tabular-nums">{row.source}</td>
                <td class="px-1 py-1 text-right tabular-nums">{row.imported}</td>
                <td class="px-1 py-1 text-right tabular-nums">{row.review}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
      {#if sum.retention && sum.retention.imported > 0}
        <div data-testid="migration-retention-note">
          <Banner tone="warn">
            {f.run.retentionNote
              .replace('{n}', String(sum.retention.imported))
              .replace('{d}', String(sum.retention.defaultDays))
              .replace('{due}', String(sum.retention.dueNowAtDefault))}
          </Banner>
        </div>
      {/if}
      {#if sum.issues.length}
        <div class="flex flex-col gap-1">
          <h4 class="m-0 text-sm font-semibold">{f.run.issuesTitle}</h4>
          <ul class="m-0 list-disc pl-5 text-sm">
            {#each sum.issues as issue (issue.code)}
              <li>
                <span class="font-medium tabular-nums">{issue.count}</span>
                {f.run.issueNames[issue.code] ?? issue.code}
              </li>
            {/each}
          </ul>
        </div>
      {/if}
    </div>
  {:else if rows.length}
    <dl class="divide-border m-0 divide-y">
      {#each rows as row (row.key)}
        <div class={rowClass}>
          <dt class="text-muted-foreground break-all">{row.key}</dt>
          <dd class="m-0 font-medium tabular-nums">{row.value}</dd>
        </div>
      {/each}
    </dl>
  {:else}
    <p class="text-muted-foreground m-0 text-sm">{f.run.noReport}</p>
  {/if}
  <details class="rounded-lg border px-4 py-2">
    <summary class="min-h-6 cursor-pointer text-sm font-medium">{f.run.report}</summary>
    <pre class="mt-2 overflow-x-auto text-xs">{JSON.stringify(job.report, null, 2)}</pre>
  </details>
{/snippet}

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title="Umstieg" description={ui.description}>
    {#snippet badges()}
      <StatusChip tone={overall.tone} label={overall.label} pulse={jobs[0]?.state === 'running'} />
    {/snippet}
  </PageHeader>
  <Stepper steps={stepList} current={step} {reached} label={ui.stepsLabel} />
  <p class="sr-only" aria-live="polite">
    {f.stepOf.replace('{n}', String(step + 1)).replace('{m}', String(MIGRATION_STEPS))}: {stepList[
      step
    ]?.label}
  </p>
  {#if error}
    <Banner tone="danger">
      {error}
      {#snippet action()}
        <Button type="button" variant="outline" onclick={load}>{f.retry}</Button>
      {/snippet}
    </Banner>
  {/if}
  {#if notice}<Banner tone="ok">{notice}</Banner>{/if}

  {#if step === 0}
    <Panel title={f.source.title} description={f.source.description}>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void test();
        }}
        class="min-w-0"
      >
        <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0 sm:grid-cols-2">
          <Row id="mig-host" label={f.source.host}>
            <Input id="mig-host" bind:value={host} required autocomplete="off" />
          </Row>
          <Row id="mig-port" label={f.source.port}>
            <Input id="mig-port" type="number" min="1" max="65535" bind:value={port} required />
          </Row>
          <Row id="mig-db" label={f.source.database}>
            <Input id="mig-db" bind:value={database} required autocomplete="off" />
          </Row>
          <Row id="mig-user" label={f.source.user}>
            <Input id="mig-user" bind:value={username} required autocomplete="off" />
          </Row>
          <Row id="mig-pass" optional label={f.source.password}>
            <Input id="mig-pass" type="password" bind:value={password} autocomplete="off" />
          </Row>
          <Row id="mig-tls" label={f.source.tls}>
            <Select id="mig-tls" bind:value={tls}>
              <option value="verify">{ui.tlsVerify}</option>
              <option value="disable">{ui.tlsDisable}</option>
            </Select>
          </Row>
        </fieldset>
        <div class="mt-4 flex flex-wrap items-center gap-3">
          <Button type="submit" variant={checkedSchema ? 'outline' : 'default'} disabled={busy}
            >{busy ? f.source.checking : checkedSchema ? f.source.recheck : f.source.check}</Button
          >
          <p class="text-muted-foreground m-0 text-sm">
            {f.netsPrefix}
            <a href="/settings" class="text-brand-ink underline underline-offset-4"
              ><code class="font-mono text-[0.9em]">migration.allowedNets</code> {f.netsLink}</a
            >.
          </p>
        </div>
      </form>
      {#if busy}
        <div class="mt-4 flex flex-col gap-2" aria-busy="true">
          <p role="status" class="text-muted-foreground m-0 text-sm">{f.source.checking}</p>
          <Skeleton class="h-10 rounded-md" />
        </div>
      {/if}
      {#if checkedSchema && inventory && !busy}
        <section
          class="mt-5 flex flex-col gap-3 rounded-lg border p-4"
          aria-label={f.source.reportTitle}
        >
          <h3 class="m-0 text-base font-semibold">{f.source.reportTitle}</h3>
          <Banner tone="ok">{f.source.reportOk}</Banner>
          {#if inventory.packet}
            <Banner tone="warn"
              >{f.source.packetTooSmall
                .replace('{limit}', String(inventory.packet.limitMiB))
                .replace('{largest}', String(inventory.packet.largestMiB))
                .replace('{needed}', String(inventory.packet.neededMiB))
                .replace('{recommended}', String(inventory.packet.recommendedMiB))}</Banner
            >
          {/if}
          <dl class="divide-border m-0 divide-y">
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.source.schema}</dt>
              <dd class="m-0 font-mono text-xs break-all">{checkedSchema}</dd>
            </div>
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.source.forms}</dt>
              <dd class="m-0 font-medium tabular-nums">{inventory.formIds.length}</dd>
            </div>
            {#each countRows(inventory.counts) as row (row.key)}
              <div class={rowClass}>
                <dt class="text-muted-foreground break-all">{row.key}</dt>
                <dd class="m-0 font-medium tabular-nums">{row.value}</dd>
              </div>
            {/each}
          </dl>
        </section>
      {/if}
      <StepNav
        {step}
        total={MIGRATION_STEPS}
        canNext={canAdvance(step, reached)}
        onback={goBack}
        onnext={goNext}
        hint={f.source.needCheck}
      />
    </Panel>
  {:else if step === 1}
    <Panel title={f.mapping.title} description={f.mapping.description}>
      <form
        class="flex min-w-0 flex-col gap-6"
        onsubmit={(e) => {
          e.preventDefault();
          void start();
        }}
      >
        {#if inventory}
          <p class="text-muted-foreground m-0 text-sm">
            <StatusChip tone="ok" label={f.mapping.adopted} />
            {f.source.forms}: {forms.length}
          </p>
        {:else}
          <Banner tone="info">{f.mapping.adoptedNone}</Banner>
        {/if}
        {#if sourceChanged}<Banner tone="warn">{f.mapping.sourceChanged}</Banner>{/if}
        <fieldset disabled={busy} class="m-0 flex min-w-0 flex-col gap-6 border-0 p-0">
          <section class="flex min-w-0 flex-col gap-3" aria-labelledby="mig-customers-title">
            <h3 id="mig-customers-title" class="m-0 text-base font-semibold">
              {f.mapping.customersTitle}
            </h3>
            {#each customers as entry, index (index)}
              {@const suffix =
                customers.length > 1
                  ? ` (${f.mapping.customerN.replace('{n}', String(index + 1))})`
                  : ''}
              <div class="grid min-w-0 gap-4 rounded-lg border p-3 sm:grid-cols-2">
                <Row id={`mig-existing-${index}`} label={f.mapping.existing + suffix}>
                  <Select
                    id={`mig-existing-${index}`}
                    value={tenants.some((tenant) => tenant.id === entry.id) ? entry.id : ''}
                    onchange={(e) => setCustomer(index, e.currentTarget.value)}
                  >
                    <option value="">{f.mapping.newCustomer}</option>
                    {#each tenants as tenant (tenant.id)}<option value={tenant.id}
                        >{tenant.name}</option
                      >{/each}
                  </Select>
                </Row>
                <Row
                  id={`mig-name-${index}`}
                  label={f.mapping.name + suffix}
                  hint={index === 0 ? f.mapping.nameHint : undefined}
                >
                  <Input id={`mig-name-${index}`} bind:value={entry.name} required />
                </Row>
                {#if index > 0}
                  <div class="sm:col-span-2">
                    <Button
                      type="button"
                      variant="outline"
                      onclick={() => (customers = customers.filter((_, i) => i !== index))}
                      >{f.mapping.removeCustomer.replace('{n}', String(index + 1))}</Button
                    >
                  </div>
                {/if}
              </div>
            {/each}
            <div>
              <Button
                type="button"
                variant="outline"
                onclick={() => (customers = [...customers, { id: crypto.randomUUID(), name: '' }])}
                >{f.mapping.addCustomer}</Button
              >
            </div>
          </section>

          <Row id="mig-namespace" label={f.mapping.namespace} hint={f.mapping.namespaceHint}>
            <Input id="mig-namespace" bind:value={namespace} required />
          </Row>

          <section class="flex min-w-0 flex-col gap-2" aria-labelledby="mig-forms-title">
            <h3 id="mig-forms-title" class="m-0 text-base font-semibold">{f.mapping.formsTitle}</h3>
            {#if !forms.length}
              <p class="text-muted-foreground m-0 text-sm">{f.mapping.formsNone}</p>
            {:else}
              {#if customers.length === 1}
                <p class="text-muted-foreground m-0 text-sm">
                  {f.mapping.formsAll.replace('{n}', String(forms.length))}
                </p>
              {/if}
              <ul class="divide-border m-0 list-none divide-y p-0" data-testid="migration-forms">
                {#each forms as form (form.id)}
                  <li
                    class="flex min-w-0 flex-wrap items-center justify-between gap-2 py-2 text-sm"
                  >
                    <span class="min-w-0">
                      <span class="block font-medium break-words">{label(form.name)}</span>
                      <code class="text-muted-foreground block font-mono text-xs break-all"
                        >{form.id}</code
                      >
                    </span>
                    {#if customers.length > 1}
                      <Select
                        id={`mig-form-${form.id}`}
                        aria-label={f.mapping.customerFor.replace('{name}', label(form.name))}
                        value={formCustomers[form.id] ?? ''}
                        onchange={(e) =>
                          (formChoice = { ...formChoice, [form.id]: e.currentTarget.value })}
                      >
                        {#each customers as entry, index (entry.id)}<option value={entry.id}
                            >{customerName(entry.id) ||
                              f.mapping.customerN.replace('{n}', String(index + 1))}</option
                          >{/each}
                      </Select>
                    {/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </section>

          <section class="flex min-w-0 flex-col gap-2" aria-labelledby="mig-conn-title">
            <h3 id="mig-conn-title" class="m-0 text-base font-semibold">
              {f.mapping.connectionsTitle}
            </h3>
            {#if !connections.length}
              <p class="text-muted-foreground m-0 text-sm">{f.mapping.connectionsNone}</p>
            {:else}
              <p class="text-muted-foreground m-0 text-sm">
                {customers.length === 1 ? f.mapping.connectionsAll : f.mapping.connectionsDerived}
              </p>
              <ul class="divide-border m-0 list-none divide-y p-0">
                {#each connections as connection (connection.id)}
                  {@const owners = built.plan.connectionCustomers[connection.id] ?? []}
                  <li
                    class="flex min-w-0 flex-wrap items-center justify-between gap-2 py-2 text-sm"
                  >
                    <span class="min-w-0">
                      <span class="block font-medium break-words"
                        >{label(connection.name)}
                        {#if f.mapping.kinds[connection.kind]}<span class="text-muted-foreground"
                            >({f.mapping.kinds[connection.kind]})</span
                          >{/if}</span
                      >
                      <code class="text-muted-foreground block font-mono text-xs break-all"
                        >{connection.id}</code
                      >
                      {#if connection.verifyCertificateOff}<span
                          class="mt-1 block text-xs font-medium text-amber-700 dark:text-amber-400"
                          >{f.mapping.verifyOff}</span
                        >{/if}
                    </span>
                    {#if customers.length > 1}
                      <Select
                        id={`mig-conn-${connection.id}`}
                        aria-label={f.mapping.customerFor.replace('{name}', label(connection.name))}
                        value={owners.length === 1 ? owners[0] : ''}
                        onchange={(e) =>
                          (connectionChoice = {
                            ...connectionChoice,
                            [connection.id]: e.currentTarget.value,
                          })}
                      >
                        <option value=""
                          >{owners.length > 1
                            ? owners.map(customerName).join(', ')
                            : f.mapping.choose}</option
                        >
                        {#each customers as entry, index (entry.id)}<option value={entry.id}
                            >{customerName(entry.id) ||
                              f.mapping.customerN.replace('{n}', String(index + 1))}</option
                          >{/each}
                      </Select>
                    {/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </section>

          <section
            class="flex min-w-0 flex-col gap-2"
            aria-labelledby="mig-keys-title"
            data-testid="migration-keys"
          >
            <h3 id="mig-keys-title" class="m-0 text-base font-semibold">{f.mapping.keysTitle}</h3>
            <p class="text-muted-foreground m-0 text-sm">{f.mapping.keysHint}</p>
            {#if warnings.affectedSubmissions > 0}
              <Banner tone="danger" title={f.mapping.warnTitle}>
                <ul class="m-0 list-disc pl-5" data-testid="migration-key-warning">
                  {#if warnings.missing.length}<li>
                      {f.mapping.warnMissing
                        .replace(
                          '{n}',
                          String(warnings.missing.reduce((s, u) => s + u.submissions, 0)),
                        )
                        .replace('{list}', warnings.missing.map((u) => u.kid).join(', '))}
                    </li>{/if}
                  {#if warnings.unusable.length}<li>
                      {f.mapping.warnUnusable
                        .replace(
                          '{n}',
                          String(warnings.unusable.reduce((s, u) => s + u.submissions, 0)),
                        )
                        .replace('{list}', warnings.unusable.map((u) => u.kid).join(', '))}
                    </li>{/if}
                  {#if warnings.foreign.length}<li>
                      {f.mapping.warnForeign.replace(
                        '{list}',
                        warnings.foreign.map((u) => u.kid).join(', '),
                      )}
                    </li>{/if}
                </ul>
              </Banner>
            {/if}
            {#if inventory?.keyUsage && !inventory.keyUsage.complete}
              <Banner tone="warn"
                >{f.mapping.usageIncomplete.replace(
                  '{n}',
                  String(inventory.keyUsage.scannedSubmissions),
                )}</Banner
              >
            {/if}
            {#if inventory && inventory.keysComplete === false}
              <Banner tone="warn">{f.mapping.keysIncomplete}</Banner>
            {/if}
            {#if !keys.length}
              <p class="text-muted-foreground m-0 text-sm">{f.mapping.keysNone}</p>
            {:else}
              <p class="text-muted-foreground m-0 text-sm">{f.mapping.keysAuto}</p>
              <ul class="divide-border m-0 list-none divide-y p-0">
                {#each keys as key (key.kid)}
                  {@const owner = built.plan.keyCustomers[key.kid]}
                  {@const generation = built.plan.keyGenerationNumbers[key.kid]}
                  <li class="flex min-w-0 flex-col gap-1 py-2 text-sm">
                    <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
                      <code class="font-mono text-xs break-all">{key.kid}</code>
                      <StatusChip
                        tone={key.status === 'aktiv'
                          ? 'ok'
                          : key.status === 'auslaufend'
                            ? 'info'
                            : 'warn'}
                        label={f.mapping.keyStatus[key.status] ?? key.status}
                      />
                      {#if key.createdAt !== null}<span class="text-muted-foreground"
                          >{f.mapping.keyCreated.replace(
                            '{date}',
                            formatDay(key.createdAt * 1000),
                          )}</span
                        >{/if}
                      <span class="text-muted-foreground tabular-nums"
                        >{f.mapping.keySubmissions.replace('{n}', String(usageOf(key.kid)))}</span
                      >
                      {#if keyImportable(key) && generation}<span class="tabular-nums"
                          >{f.mapping.keyGeneration.replace('{n}', String(generation))}</span
                        >{/if}
                    </div>
                    {#if !keyImportable(key)}
                      <p class="text-red-700 dark:text-destructive m-0">
                        {f.mapping.keySkipped.replace(
                          '{reason}',
                          key.publicKeyValid ? f.mapping.keySkipStatus : f.mapping.keySkipPublicKey,
                        )}
                      </p>
                    {:else if customers.length > 1}
                      <Select
                        id={`mig-key-${key.kid}`}
                        aria-label={f.mapping.customerFor.replace('{name}', `kid ${key.kid}`)}
                        value={owner ?? ''}
                        onchange={(e) =>
                          (keyChoice = { ...keyChoice, [key.kid]: e.currentTarget.value })}
                      >
                        <option value="">{f.mapping.choose}</option>
                        {#each customers as entry, index (entry.id)}<option value={entry.id}
                            >{customerName(entry.id) ||
                              f.mapping.customerN.replace('{n}', String(index + 1))}</option
                          >{/each}
                      </Select>
                      {#if !owner}<p class="text-muted-foreground m-0">{f.mapping.keyOpen}</p>{/if}
                    {:else if owner}
                      <p class="text-muted-foreground m-0">{customerName(owner)}</p>
                    {/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </section>

          <details class="rounded-lg border px-4 py-3">
            <summary class="min-h-6 cursor-pointer text-sm font-medium"
              >{f.mapping.advanced}</summary
            >
            <div class="mt-3 grid gap-4">
              <div class="flex flex-col gap-1">
                <h4 class="m-0 text-sm font-medium">{f.mapping.customerId}</h4>
                <ul class="m-0 list-none p-0">
                  {#each customers as entry, index (index)}
                    <li class="text-sm">
                      {customerName(entry.id)}:
                      <code class="font-mono text-xs break-all">{entry.id}</code>
                    </li>
                  {/each}
                </ul>
              </div>
              <Row id="mig-snapshot" label={f.mapping.snapshot} hint={f.mapping.snapshotHint}>
                <Input
                  id="mig-snapshot"
                  bind:value={snapshot}
                  pattern={'[0-9a-f]{64}'}
                  required
                  class="font-mono"
                />
              </Row>
              <Row id="mig-schema" label={f.mapping.schema}>
                <Input
                  id="mig-schema"
                  bind:value={expectedSchema}
                  pattern={'[0-9a-f]{64}'}
                  required
                  class="font-mono"
                />
              </Row>
              <Row id="mig-extra" label={f.mapping.extra} hint={f.mapping.extraHint}>
                <Textarea id="mig-extra" bind:value={extra} class="font-mono" />
              </Row>
            </div>
          </details>
        </fieldset>

        <section
          class="flex min-w-0 flex-col gap-2 rounded-lg border p-4"
          aria-labelledby="mig-summary-title"
          data-testid="migration-summary"
        >
          <h3 id="mig-summary-title" class="m-0 text-base font-semibold">
            {f.mapping.summaryTitle}
          </h3>
          <dl class="divide-border m-0 divide-y">
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.mapping.summaryCustomers}</dt>
              <dd class="m-0 font-medium">{customers.map((c) => customerName(c.id)).join(', ')}</dd>
            </div>
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.mapping.summaryForms}</dt>
              <dd class="m-0 font-medium">
                {forms.length}{forms.length
                  ? `: ${forms.map((form) => label(form.name)).join(', ')}`
                  : ''}
              </dd>
            </div>
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.mapping.summaryConnections}</dt>
              <dd class="m-0 font-medium tabular-nums">
                {f.mapping.summaryAssigned
                  .replace(
                    '{n}',
                    String(
                      connections.filter((c) => built.plan.connectionCustomers[c.id]?.length)
                        .length,
                    ),
                  )
                  .replace('{m}', String(connections.length))}
              </dd>
            </div>
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.mapping.summaryKeys}</dt>
              <dd class="m-0 font-medium tabular-nums">
                {f.mapping.summaryAssigned
                  .replace(
                    '{n}',
                    String(
                      keys.filter((k) => keyImportable(k) && built.plan.keyCustomers[k.kid]).length,
                    ),
                  )
                  .replace('{m}', String(keys.length))}
              </dd>
            </div>
            <div class={rowClass}>
              <dt class="text-muted-foreground">{f.mapping.namespace}</dt>
              <dd class="m-0 font-mono text-xs break-all">{built.plan.namespace}</dd>
            </div>
          </dl>
          {#if statsRows > 0}
            <p class="m-0 text-sm" data-testid="migration-stats-notice">
              {f.mapping.statsNotice.replace('{n}', String(statsRows))}
            </p>
          {/if}
          {#if issues.length}
            <p class="text-muted-foreground m-0 text-sm" id="mig-missing">
              {f.mapping.missing.replace(
                '{list}',
                issues.map((issue) => f.mapping.issue[issue]).join(', '),
              )}
            </p>
          {:else}
            <p class="m-0 text-sm">{f.mapping.ready}</p>
          {/if}
        </section>
        <StepNav
          {step}
          total={MIGRATION_STEPS}
          canNext={canAdvance(step, reached)}
          onback={goBack}
          onnext={goNext}
        >
          <Button
            type="submit"
            disabled={busy || issues.length > 0}
            aria-describedby={issues.length ? 'mig-missing' : undefined}
            >{busy ? f.mapping.starting : f.mapping.start}</Button
          >
        </StepNav>
      </form>
    </Panel>
  {:else if step === 2}
    <Panel title={f.run.title} description={f.run.description}>
      {#if !loaded}
        <div class="flex flex-col gap-2" aria-busy="true">
          <p role="status" class="text-muted-foreground m-0 text-sm">{f.loading}</p>
          <Skeleton class="h-24 rounded-md" />
        </div>
      {:else if !jobs.length}
        <EmptyState icon="inbox" title={f.run.emptyTitle} description={f.run.emptyBody}>
          {#snippet action()}
            <Button variant="outline" onclick={() => (step = 1)}>{f.run.toMapping}</Button>
          {/snippet}
        </EmptyState>
      {:else}
        <p class="text-muted-foreground m-0 mb-3 text-sm">
          {f.updated.replace('{time}', updated || f.updatedPending)}
        </p>
        <div class="flex flex-col gap-4">
          {#each jobs as job (job.id)}
            <section
              aria-label={`Lauf ${job.id}`}
              class="flex flex-col gap-3 rounded-lg border p-4"
            >
              <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
                <h3 class="m-0 text-base font-semibold">
                  {job.dryRun ? f.run.dry : f.run.real}: {migrationStates[job.state] ?? job.state}
                </h3>
                <StatusChip
                  tone={stateTones[job.state] ?? 'idle'}
                  label={job.dryRun ? ui.steps.review : ui.steps.import}
                  pulse={job.state === 'running'}
                />
              </div>
              <p role="status" class="m-0 text-sm">{f.run.phase.replace('{phase}', job.phase)}</p>
              {#if job.state === 'running'}<progress aria-label={f.run.running} class="h-2 w-full"
                ></progress>{/if}
              {#if job.state === 'review' && job.dryRun}<Banner tone="info">{f.run.dryDone}</Banner
                >{/if}
              {#if job.error}<p role="alert" class="text-red-700 dark:text-destructive m-0 text-sm">
                  {f.run.failed.replace('{phase}', job.phase).replace(
                    '{error}',
                    describeJobError(job.error, {
                      reasons: f.run.errorReasons,
                      codes: f.run.errorCodes,
                      column: f.run.errorColumn,
                      errorNumber: f.run.errorNumber,
                      errorObject: f.run.errorObject,
                    }),
                  )}
                </p>{/if}
              {@render report(job)}
              <div class="flex flex-wrap gap-2">
                <Button variant="outline" onclick={() => download(job)}>{f.run.download}</Button>
                {#if ['queued', 'running'].includes(job.state)}<Button
                    variant="outline"
                    onclick={() => action(job.id, 'pause')}>{f.run.pause}</Button
                  >{/if}
                {#if ['paused', 'failed'].includes(job.state) && !quiesceErrors.includes(job.error)}<Button
                    onclick={() => action(job.id, 'resume')}>{f.run.resume}</Button
                  >{/if}
                {#if job.state === 'review' && job.dryRun}<Button
                    onclick={() => action(job.id, 'import')}>{f.run.import}</Button
                  >{/if}
                {#if (job.state === 'review' && job.dryRun) || (job.state === 'failed' && job.error === 'source_changed')}<Button
                    variant="outline"
                    onclick={() => action(job.id, 'rehearse')}>{f.run.rehearse}</Button
                  >{/if}
                {#if ['paused', 'failed'].includes(job.state) || (job.state === 'review' && job.dryRun)}<Button
                    variant="outline"
                    onclick={() => action(job.id, 'remove-source')}>{f.done.remove}</Button
                  >{/if}
              </div>
            </section>
          {/each}
        </div>
      {/if}
      <StepNav
        {step}
        total={MIGRATION_STEPS}
        canNext={canAdvance(step, reached)}
        onback={goBack}
        onnext={goNext}
      />
    </Panel>
  {:else if step === 3}
    <Panel title={f.review.title} description={f.review.description}>
      {#if !loaded}
        <div class="flex flex-col gap-2" aria-busy="true">
          <p role="status" class="text-muted-foreground m-0 text-sm">{f.loading}</p>
          <Skeleton class="h-24 rounded-md" />
        </div>
      {:else if !importJob}
        <EmptyState icon="search" title={f.review.emptyTitle} description={f.review.emptyBody}>
          {#snippet action()}
            <Button variant="outline" onclick={() => (step = 2)}>{f.review.toRun}</Button>
          {/snippet}
        </EmptyState>
      {:else}
        <div class="flex flex-col gap-4">
          <section class="flex flex-col gap-3 rounded-lg border p-4">
            <h3 class="m-0 text-base font-semibold">{f.review.reportTitle}</h3>
            <p class="text-muted-foreground m-0 text-sm">
              {f.run.probe
                .replace('{probe}', importJob.probeConfirmed ? f.run.confirmed : f.run.open)
                .replace('{test}', importJob.testConfirmed ? f.run.confirmed : f.run.open)}
            </p>
            {@render report(importJob)}
            <div>
              <Button variant="outline" onclick={() => download(importJob)}>{f.run.download}</Button
              >
            </div>
          </section>
          <section class="flex flex-col gap-3 rounded-lg border p-4">
            <h3 class="m-0 text-base font-semibold">{f.review.probeTitle}</h3>
            {#if noProbe}
              <div data-testid="migration-probe-none" class="flex flex-col gap-2">
                <Banner tone="info">{f.review.probeNone}</Banner>
                {#if legacyKept}<p class="m-0 text-sm">
                    {f.review.probeNoneCount.replace('{n}', String(legacyKept))}
                  </p>{/if}
              </div>
            {:else if probe}
              <form
                class="flex flex-col gap-3"
                onsubmit={(e) => {
                  e.preventDefault();
                  void verifyProbe();
                }}
              >
                <p class="m-0 text-sm">{f.review.probeHint}</p>
                {#if probeKid}<p class="m-0 text-sm" data-testid="migration-probe-kid">
                    {f.review.probeKid.replace('{kid}', probeKid)}
                  </p>{/if}
                <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0">
                  <Row id="mig-private" label={f.review.probeKey}>
                    <Input
                      id="mig-private"
                      type="password"
                      bind:value={privateKey}
                      autocomplete="off"
                      spellcheck={false}
                      required
                    />
                  </Row>
                  <div class="flex flex-wrap gap-2">
                    <Button type="submit">{f.review.probeSubmit}</Button>
                    <Button
                      type="button"
                      variant="outline"
                      onclick={() => {
                        privateKey = '';
                        probe = undefined;
                      }}>{f.review.probeCancel}</Button
                    >
                  </div>
                </fieldset>
              </form>
            {:else}
              <div>
                <Button variant="outline" disabled={busy} onclick={() => getProbe(importJob)}
                  >{f.review.probeLoad}</Button
                >
              </div>
            {/if}
          </section>
          <section
            class="flex flex-col gap-3 rounded-lg border p-4"
            data-testid="migration-release"
          >
            <h3 class="m-0 text-base font-semibold">{f.review.releaseTitle}</h3>
            <p class="m-0 text-sm">{f.review.releaseHint}</p>
            <div>
              <Button
                variant="outline"
                disabled={busy || !importJob.probeConfirmed}
                onclick={() => releaseSubmissions(importJob)}>{f.review.releaseButton}</Button
              >
            </div>
            {#if noProbe}<p class="text-muted-foreground m-0 text-sm" role="status">
                {f.review.releaseNone}
              </p>{:else if !importJob.probeConfirmed}<p
                class="text-muted-foreground m-0 text-sm"
                role="status"
              >
                {f.review.releaseNeedsProbe}
              </p>{/if}
            {#if released}<p class="m-0 text-sm" role="status" data-testid="migration-released">
                {f.review.releaseResult
                  .replace('{released}', String(released.released))
                  .replace('{kept}', String(released.kept))}
              </p>{/if}
          </section>
          <section class="flex flex-col gap-3 rounded-lg border p-4" data-testid="migration-adopt">
            <h3 class="m-0 text-base font-semibold">{f.review.adoptTitle}</h3>
            <p class="m-0 text-sm">{f.review.adoptHint}</p>
            <div>
              <Button variant="outline" onclick={() => router.navigate('/account?legacy=1')}
                >{f.review.adoptLink}</Button
              >
            </div>
          </section>
          <section class="flex flex-col gap-3 rounded-lg border p-4">
            <h3 class="m-0 text-base font-semibold">{f.review.draftTitle}</h3>
            <p class="text-muted-foreground m-0 text-sm">{f.review.draftHint}</p>
            <div>
              <Button variant="outline" onclick={() => convert(importJob)}
                >{f.review.draftStart}</Button
              >
            </div>
          </section>
        </div>
      {/if}
      <StepNav
        {step}
        total={MIGRATION_STEPS}
        canNext={canAdvance(step, reached)}
        onback={goBack}
        onnext={goNext}
      />
    </Panel>
  {:else}
    <Panel title={f.done.title} description={f.done.description}>
      {#if !loaded}
        <div class="flex flex-col gap-2" aria-busy="true">
          <p role="status" class="text-muted-foreground m-0 text-sm">{f.loading}</p>
          <Skeleton class="h-24 rounded-md" />
        </div>
      {:else if reached < 4}
        <EmptyState icon="search" title={f.done.emptyTitle} description={f.done.emptyBody}>
          {#snippet action()}
            <Button variant="outline" onclick={() => (step = Math.max(0, reached))}
              >{stepList[Math.max(0, reached)]?.label}</Button
            >
          {/snippet}
        </EmptyState>
      {:else}
        <div class="flex flex-col gap-4">
          {#if closedJob}
            <section
              class="flex flex-col gap-3 rounded-lg border p-4"
              data-testid="migration-closed"
            >
              <h3 class="m-0 text-base font-semibold">{f.done.closedTitle}</h3>
              <Banner tone="ok">{f.done.closed}</Banner>
              <ul class="m-0 list-disc pl-5 text-sm">
                <li>{f.done.closedImport}</li>
                {#if closedJob.probeConfirmed}<li>{f.done.closedProbe}</li>{/if}
                {#if closedJob.testConfirmed}<li>{f.done.closedTest}</li>{/if}
                <li>{f.done.closedRemoved}</li>
              </ul>
              <p class="text-muted-foreground m-0 text-sm">{f.done.closedNote}</p>
            </section>
          {:else}
            <section class="flex flex-col gap-2 rounded-lg border p-4">
              <h3 class="m-0 text-base font-semibold">{f.done.checklistTitle}</h3>
              <ul class="m-0 list-disc pl-5 text-sm">
                {#each f.done.checklist as item (item)}<li>{item}</li>{/each}
              </ul>
              <p class="text-muted-foreground m-0 text-sm">{f.done.noteLead}</p>
              <div>
                <Button variant="outline" onclick={() => router.navigate('/account?legacy=1')}
                  >{f.review.adoptLink}</Button
                >
              </div>
            </section>
            <section class="flex flex-col gap-2 rounded-lg border p-4">
              <h3 class="m-0 text-base font-semibold">{f.done.rollbackTitle}</h3>
              <p class="m-0 text-sm">{f.done.rollback}</p>
            </section>
            {#if importJob}
              <section class="flex flex-col gap-2 rounded-lg border p-4">
                <h3 class="m-0 text-base font-semibold">{f.done.removeTitle}</h3>
                <p class="text-muted-foreground m-0 text-sm">{f.done.removeHint}</p>
                {#if noProbe}
                  <p class="m-0 text-sm" data-testid="migration-without-probe">
                    {f.done.withoutProbe}
                  </p>
                  <label class="flex items-start gap-2 text-sm">
                    <input type="checkbox" class="mt-1" bind:checked={withoutProbeOk} />
                    <span>{f.done.withoutProbeConfirm}</span>
                  </label>
                {/if}
                <div>
                  <Button
                    variant="outline"
                    disabled={removeMissing.length > 0 || (noProbe && !withoutProbeOk)}
                    onclick={() => action(importJob.id, 'remove-source')}>{f.done.remove}</Button
                  >
                </div>
                {#if removeMissing.length}<p
                    class="text-muted-foreground m-0 text-sm"
                    role="status"
                  >
                    {f.done.missing.replace('{items}', removeMissing.join(', '))}
                  </p>{/if}
              </section>
            {/if}
          {/if}
          <a
            href="/settings"
            class="text-brand-ink inline-flex min-h-6 items-center text-sm underline underline-offset-4"
            >{f.done.disable}</a
          >
        </div>
      {/if}
      <StepNav
        {step}
        total={MIGRATION_STEPS}
        canNext={canAdvance(step, reached)}
        onback={goBack}
        onnext={goNext}
      />
    </Panel>
  {/if}
</div>
