<script lang="ts">
  import { formatClock } from '$lib/format';
  import { confirmAction } from '$lib/confirm.svelte';
  import { verifyMigrationProbe } from '$lib/crypto/migrationProbe';
  import { parseLegacyPrivateKey } from '$lib/crypto/legacyAdoption';
  import { router } from '$lib/router.svelte';
  import { onMount } from 'svelte';
  import { http, adminApi } from '$lib/api';
  import type { Tenant } from '$lib/api/admin';
  import { createImportPlan, migrationStates } from '$lib/setup';
  import { reauthenticate, stepUp } from '$lib/admin/guard.svelte';
  import { needsFreshLogin } from '$lib/admin/describe';
  import {
    MIGRATION_STEPS,
    canAdvance,
    countRows,
    describeJobError,
    isSha256,
    mappingIssues,
    landingStep,
    reachedStep,
    reportRows,
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
  let inventory = $state<{ formIds: string[]; counts: Record<string, number> }>();
  let assignments = $state<{ customer: string; name: string; forms: string }[]>([]);
  let customer = $state(''),
    name = $state(''),
    forms = $state(''),
    namespace = $state(''),
    snapshot = $state('');
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
  let privateKey = $state(''),
    deltaHash = $state('');
  let probe = $state<{ wire: string; hash: string; jobId: string }>();
  let step = $state(0);
  let prevReached = -1;
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
  const issues = $derived(
    mappingIssues({ customer, name, forms, namespace, snapshot, expectedSchema }),
  );
  const importJob = $derived(jobs.find((job) => job.state === 'review' && !job.dryRun));
  const source = () => ({ host, port, database, username, password, tls });
  const goBack = () => (step = Math.max(0, step - 1));
  const goNext = () => {
    if (canAdvance(step, reached)) step += 1;
  };
  async function request<T>(
    method: 'GET' | 'POST',
    path: string,
    body?: unknown,
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
        : r.error.status === 422 && r.error.detail
          ? r.error.detail
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
  /** Fills the plan from the source inventory so a single-customer migration needs no hand-typed ids. */
  async function prefill(r: {
    schemaHMAC: string;
    formIds: string[];
    connectionIds?: string[];
    counts: Record<string, number>;
  }) {
    if (!customer) customer = crypto.randomUUID();
    if (!forms) forms = r.formIds.join('\n');
    if (!expectedSchema) expectedSchema = r.schemaHMAC;
    if (!snapshot) {
      const bytes = new TextEncoder().encode(
        JSON.stringify({ s: r.schemaHMAC, c: r.counts, f: r.formIds }),
      );
      const digest = await crypto.subtle.digest('SHA-256', bytes);
      snapshot = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
    }
    if ((!extra || extra.trim() === '{}') && r.connectionIds?.length)
      extra = JSON.stringify({
        connectionCustomers: Object.fromEntries(r.connectionIds.map((id) => [id, [customer]])),
      });
  }
  async function test() {
    busy = true;
    error = '';
    checkedSchema = '';
    const r = await request<{
      schemaHMAC: string;
      formIds: string[];
      connectionIds?: string[];
      counts: Record<string, number>;
    }>('POST', '/migration/test', source());
    if (r) {
      checkedSchema = r.schemaHMAC;
      inventory = r;
      await prefill(r);
    }
    busy = false;
  }
  async function start() {
    busy = true;
    error = '';
    try {
      const base = createImportPlan(customer, name, forms, namespace, snapshot);
      for (const mapping of assignments) {
        const next = createImportPlan(
          mapping.customer,
          mapping.name,
          mapping.forms,
          namespace,
          snapshot,
        );
        if (Object.keys(next.formCustomers).some((id) => id in base.formCustomers))
          throw new Error('duplicate');
        Object.assign(base.customers, next.customers);
        Object.assign(base.formCustomers, next.formCustomers);
      }
      const plan = {
        ...base,
        ...JSON.parse(extra),
      };
      await request('POST', '/migration/jobs', {
        source: source(),
        plan,
        expectedSchema,
        dryRun: true,
      });
      password = '';
      await load();
    } catch {
      error = f.planInvalid;
    }
    busy = false;
  }
  async function action(id: string, action: string) {
    error = '';
    await request('POST', `/migration/jobs/${id}/${action}`);
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
  async function delta(job: Job) {
    if (!isSha256(deltaHash)) {
      error = f.msg.deltaHash;
      return;
    }
    await request('POST', `/migration/jobs/${job.id}/delta`, { dumpSHA256: deltaHash });
    deltaHash = '';
    await load();
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
  {#if rows.length}
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
        onsubmit={(e) => {
          e.preventDefault();
          if (!issues.length) void start();
        }}
      >
        {#if inventory}
          <p class="text-muted-foreground m-0 mb-4 text-sm">
            <StatusChip tone="ok" label={f.mapping.adopted} />
            {f.source.forms}: {inventory.formIds.length}
          </p>
        {:else}
          <p class="text-muted-foreground m-0 mb-4 text-sm">{f.mapping.adoptedNone}</p>
        {/if}
        <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0 sm:grid-cols-2">
          <div class="sm:col-span-2">
            <Row id="mig-existing" label={f.mapping.existing}>
              <Select
                id="mig-existing"
                onchange={(e) => {
                  const selected = tenants.find((t) => t.id === e.currentTarget.value);
                  if (selected) {
                    customer = selected.id;
                    name = selected.name;
                  }
                }}
              >
                <option value="">{f.mapping.newCustomer}</option>
                {#each tenants as tenant (tenant.id)}<option value={tenant.id}>{tenant.name}</option
                  >{/each}
              </Select>
            </Row>
          </div>
          <Row id="mig-name" label={f.mapping.name}>
            <Input id="mig-name" bind:value={name} required />
          </Row>
          <Row id="mig-namespace" label={f.mapping.namespace} hint={f.mapping.namespaceHint}>
            <Input id="mig-namespace" bind:value={namespace} required />
          </Row>
          <div class="sm:col-span-2">
            <Row id="mig-forms" label={f.mapping.forms}>
              <Textarea id="mig-forms" bind:value={forms} required class="font-mono" />
            </Row>
          </div>
          <details class="rounded-lg border px-4 py-3 sm:col-span-2">
            <summary class="min-h-6 cursor-pointer text-sm font-medium"
              >{f.mapping.advanced}</summary
            >
            <div class="mt-3 grid gap-4">
              <div class="flex flex-col gap-2">
                <Row id="mig-customer" label={f.mapping.customerId}>
                  <Input id="mig-customer" bind:value={customer} required class="font-mono" />
                </Row>
                <div>
                  <Button
                    type="button"
                    variant="outline"
                    onclick={() => (customer = crypto.randomUUID())}>{f.mapping.newId}</Button
                  >
                </div>
              </div>
              <Row id="mig-snapshot" label={f.mapping.snapshot}>
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
          {#if assignments.length}
            <div class="sm:col-span-2">
              <h3 class="m-0 mb-1 text-sm font-medium">{f.mapping.assignments}</h3>
              <ul class="m-0 list-none p-0 text-sm">
                {#each assignments as mapping, index (index)}
                  <li>{mapping.name}: {mapping.forms}</li>
                {/each}
              </ul>
            </div>
          {/if}
          <div class="sm:col-span-2">
            <Button
              type="button"
              variant="outline"
              onclick={() => {
                assignments = [...assignments, { customer, name, forms }];
                customer = '';
                name = '';
                forms = '';
              }}>{f.mapping.addAssignment}</Button
            >
          </div>
        </fieldset>
        {#if issues.length}
          <p class="text-muted-foreground m-0 mt-4 text-sm" id="mig-missing">
            {f.mapping.missing.replace(
              '{list}',
              issues.map((issue) => f.mapping.issue[issue]).join(', '),
            )}
          </p>
        {/if}
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
                {#if ['paused', 'failed'].includes(job.state)}<Button
                    onclick={() => action(job.id, 'resume')}>{f.run.resume}</Button
                  >{/if}
                {#if job.state === 'review' && job.dryRun}<Button
                    onclick={() => action(job.id, 'import')}>{f.run.import}</Button
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
            {#if probe}
              <form
                class="flex flex-col gap-3"
                onsubmit={(e) => {
                  e.preventDefault();
                  void verifyProbe();
                }}
              >
                <p class="m-0 text-sm">{f.review.probeHint}</p>
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
            <h3 class="m-0 text-base font-semibold">{f.review.deltaTitle}</h3>
            <Row id="mig-delta" label={f.review.deltaHash}>
              <Input
                id="mig-delta"
                bind:value={deltaHash}
                pattern={'[0-9a-f]{64}'}
                class="font-mono"
              />
            </Row>
            <p class="text-muted-foreground m-0 text-sm">{f.review.deltaHint}</p>
            <div>
              <Button variant="outline" disabled={busy} onclick={() => delta(importJob)}
                >{f.review.deltaStart}</Button
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
          {#if jobs[0]?.state === 'closed'}<Banner tone="ok">{f.done.closed}</Banner>{/if}
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
              <div>
                <Button variant="outline" onclick={() => action(importJob.id, 'remove-source')}
                  >{f.done.remove}</Button
                >
              </div>
            </section>
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
