<script lang="ts">
  import { verifyMigrationProbe } from '$lib/crypto/migrationProbe';
  import { fromBase64Url } from '$lib/crypto/packageV2';
  import { onMount } from 'svelte';
  import { http, adminApi } from '$lib/api';
  import type { Tenant } from '$lib/api/admin';
  import { createImportPlan, migrationStates } from '$lib/setup';
  import { reauthenticate } from '$lib/admin/guard.svelte';
  import { needsFreshLogin } from '$lib/admin/describe';
  import { t } from '$lib/i18n';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import FormSection from '$lib/components/admin/FormSection.svelte';
  import Stepper from '$lib/components/admin/Stepper.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
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
    updated = $state('');
  let activeSecret: Uint8Array | undefined;
  let privateKey = $state(''),
    deltaHash = $state('');
  let probe = $state<{ wire: string; hash: string; jobId: string }>();
  const ui = t.formKit.migration;
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
  /** Active phase of the newest run; derived from the real job state, never invented. */
  const currentStep = $derived.by(() => {
    const job = jobs[0];
    if (!job) return checkedSchema ? 1 : 0;
    if (job.state === 'closed') return 4;
    if (job.state === 'review') return job.dryRun ? 2 : 3;
    return 2;
  });
  const overall = $derived.by((): { tone: Tone; label: string } => {
    const job = jobs[0];
    if (!job) return { tone: 'idle', label: ui.none };
    return {
      tone: stateTones[job.state] ?? 'idle',
      label: migrationStates[job.state] ?? job.state,
    };
  });
  const source = () => ({ host, port, database, username, password, tls });
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
        ? 'Keine Berechtigung oder der Umstieg ist deaktiviert.'
        : 'Die Verbindung wurde unterbrochen oder die Prüfung ist fehlgeschlagen. Der bestätigte Fortschritt bleibt erhalten. Bitte Phase prüfen und erneut versuchen.';
  }
  async function load() {
    if (!tenants.length) {
      const t = await adminApi.tenants();
      if (t.ok) tenants = t.data.items;
    }
    const r = await request<{ items: Job[] }>('GET', '/migration/jobs');
    if (r) {
      jobs = r.items;
      updated = new Date().toLocaleTimeString('de-DE');
    }
  }
  onMount(() => {
    void load();
    const timer = setInterval(() => void load(), 3000);
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
      error = 'Bitte Zuordnung und zusätzliche Planangaben prüfen.';
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
      secret = fromBase64Url(privateKey.trim());
      activeSecret = secret;
      privateKey = '';
      if (secret.length !== 32) throw new Error('key');
      const testHash = await verifyMigrationProbe(
        selected.wire,
        selected.hash,
        secret,
        async (hash) => {
          if (
            !window.confirm(
              'Die Probe wurde lokal authentifiziert entschlüsselt. Ergebnis bestätigen und neue Testnachricht verschlüsseln?',
            )
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
        notice =
          'Lokale Entschlüsselung bestätigt und neue Testnachricht lokal verschlüsselt und geprüft. Nur Chiffrat-Hashes wurden übertragen.';
        probe = undefined;
      }
    } catch {
      error =
        'Probe fehlgeschlagen oder abgebrochen. Schlüssel und Paketformat prüfen. Es wurde kein Klartext übertragen.';
    } finally {
      secret?.fill(0);
      activeSecret = undefined;
      privateKey = '';
      busy = false;
    }
  }
  async function delta(job: Job) {
    if (!/^[0-9a-f]{64}$/.test(deltaHash)) {
      error = 'Neuen Snapshot-SHA256 angeben.';
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
        error = 'Formular-UUID prüfen.';
        return;
      }
      if (!(await request('POST', `/migration/legacy-forms/${id}/draft`))) return;
    }
    notice =
      'Inaktive Entwurfsvorschläge erstellt. Feld-, Mail-, Domain- und Berechtigungsprüfung bleiben erforderlich.';
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
</script>

<div class="mx-auto flex w-full max-w-[960px] flex-col gap-6">
  <PageHeader title="Umstieg" description={ui.description}>
    {#snippet badges()}
      <StatusChip tone={overall.tone} label={overall.label} pulse={jobs[0]?.state === 'running'} />
    {/snippet}
  </PageHeader>
  <Stepper steps={stepList} current={currentStep} label={ui.stepsLabel} />
  {#if error}
    <Banner tone="danger">
      {error}
      {#snippet action()}
        <Button type="button" variant="outline" onclick={load}>Erneut versuchen</Button>
      {/snippet}
    </Banner>
  {/if}
  {#if notice}<Banner tone="ok">{notice}</Banner>{/if}
  <div class="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_17rem]">
    <form
      onsubmit={(e) => {
        e.preventDefault();
        void test();
      }}
      class="min-w-0"
    >
      <FormSection title="Quelle – Nur lesender Zugriff" index={0}>
        <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0 sm:grid-cols-2">
          <Row id="mig-host" label="Host">
            <Input id="mig-host" bind:value={host} required autocomplete="off" />
          </Row>
          <Row id="mig-port" label="Port">
            <Input id="mig-port" type="number" min="1" max="65535" bind:value={port} required />
          </Row>
          <Row id="mig-db" label="Datenbank">
            <Input id="mig-db" bind:value={database} required autocomplete="off" />
          </Row>
          <Row id="mig-user" label="Benutzer">
            <Input id="mig-user" bind:value={username} required autocomplete="off" />
          </Row>
          <Row id="mig-pass" label="Passwort">
            <Input id="mig-pass" type="password" bind:value={password} autocomplete="off" />
          </Row>
          <Row id="mig-tls" label="TLS-Modus">
            <Select id="mig-tls" bind:value={tls}>
              <option value="verify">Zertifikat und Host prüfen</option>
              <option value="disable">Ohne TLS (nur freigegebene Entwicklungsumgebung)</option>
            </Select>
          </Row>
          <div class="sm:col-span-2"><Button type="submit">Verbindung prüfen</Button></div>
        </fieldset>
      </FormSection>
    </form>
    <aside class="surface-card flex min-w-0 flex-col gap-3 p-5" aria-label={ui.hintsTitle}>
      <h2 class="text-[length:var(--fs-h2)] leading-[26px] font-semibold">{ui.hintsTitle}</h2>
      <p class="text-muted-foreground text-sm">{ui.hintNets}</p>
      <a
        href="/settings"
        class="text-ui-accent-ink inline-flex min-h-6 items-center text-sm underline underline-offset-4"
        >Private Netze ausdrücklich unter migration.allowedNets freigeben</a
      >
    </aside>
  </div>
  {#if checkedSchema}<Banner tone="ok"
      >Nur lesender Zugang geprüft. Schema-HMAC: <code class="break-all">{checkedSchema}</code
      ></Banner
    >{/if}
  {#if inventory}<details class="surface-card px-5 py-3">
      <summary class="min-h-6 cursor-pointer text-sm font-medium"
        >Quellinventar und Formularzuordnung</summary
      >
      <pre class="bg-surface-sunken mt-3 overflow-x-auto rounded-md p-3 text-xs">{JSON.stringify(
          inventory,
          null,
          2,
        )}</pre>
    </details>{/if}
  <form
    onsubmit={(e) => {
      e.preventDefault();
      void start();
    }}
  >
    <FormSection title="Inventar &amp; Zuordnung" index={1}>
      <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0 sm:grid-cols-2">
        <div class="sm:col-span-2">
          <Row id="mig-existing" label="Vorhandenen Kunden wählen">
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
              <option value="">Neuen Kunden zuordnen</option>
              {#each tenants as tenant (tenant.id)}<option value={tenant.id}>{tenant.name}</option
                >{/each}
            </Select>
          </Row>
        </div>
        <p class="text-muted-foreground text-sm sm:col-span-2">
          Ein neuer Kunde wird inaktiv angelegt. Bei bestehenden Kunden muss der Name exakt zum
          gespeicherten Plan passen; vorhandene Fachobjekte werden nie überschrieben.
        </p>
        <div class="flex flex-col gap-2">
          <Row id="mig-customer" label="Kunden-UUID (neu oder vorhanden)">
            <Input id="mig-customer" bind:value={customer} required />
          </Row>
          <div>
            <Button type="button" variant="outline" onclick={() => (customer = crypto.randomUUID())}
              >Neue Kundenkennung</Button
            >
          </div>
        </div>
        <Row id="mig-name" label="Kundenname">
          <Input id="mig-name" bind:value={name} required />
        </Row>
        <div class="sm:col-span-2">
          <Row id="mig-forms" label="Formular-UUIDs dieses Kunden">
            <Textarea id="mig-forms" bind:value={forms} required class="font-mono" />
          </Row>
        </div>
        <Row id="mig-namespace" label="Quellnamespace">
          <Input id="mig-namespace" bind:value={namespace} required />
        </Row>
        <Row id="mig-snapshot" label="Dump-/Snapshot-SHA256">
          <Input
            id="mig-snapshot"
            bind:value={snapshot}
            pattern={'[0-9a-f]{64}'}
            required
            class="font-mono"
          />
        </Row>
        <div class="sm:col-span-2">
          <Row
            id="mig-schema"
            label="Erwarteter Schema-HMAC (bewusst aus der Quellprüfung übernehmen)"
          >
            <Input
              id="mig-schema"
              bind:value={expectedSchema}
              pattern={'[0-9a-f]{64}'}
              required
              class="font-mono"
            />
          </Row>
        </div>
        <details class="bg-surface-sunken rounded-md px-4 py-3 sm:col-span-2">
          <summary class="min-h-6 cursor-pointer text-sm font-medium">{ui.advanced}</summary>
          <div class="mt-3">
            <Row
              id="mig-extra"
              label="Weitere bestätigte Planangaben als JSON (Verbindungen, Statistikbericht und öffentliche Schlüssel)"
              hint={ui.advancedHint}
            >
              <Textarea id="mig-extra" bind:value={extra} class="font-mono" />
            </Row>
          </div>
        </details>
        {#each assignments as mapping, index (index)}<p class="text-sm sm:col-span-2">
            {mapping.name}: {mapping.forms}
          </p>{/each}
        <div class="flex flex-wrap gap-2 sm:col-span-2">
          <Button
            type="button"
            variant="outline"
            onclick={() => {
              assignments = [...assignments, { customer, name, forms }];
              customer = '';
              name = '';
              forms = '';
            }}>Weitere Kunden-/Formularzuordnung hinzufügen</Button
          >
          <Button type="submit">Prüflauf starten</Button>
        </div>
      </fieldset>
    </FormSection>
  </form>
  <details class="surface-card px-5 py-3">
    <summary class="min-h-6 cursor-pointer text-[length:var(--fs-h2)] font-semibold"
      ><h2 class="inline">Abbruch und Rückkehrplan</h2></summary
    >
    <div class="mt-3 flex flex-col gap-3 text-sm">
      <p>
        Pause stoppt an der nächsten Objektgrenze; bestätigte Importe bleiben erhalten. Der Prüflauf
        wird vollständig zurückgerollt. Altzugriff entfernen löscht Zugangsdaten, keine importierten
        Einsendungen. Für einen vollständigen Rollback vor Umschaltung die gesicherte Ziel-Datenbank
        wiederherstellen; nach Umschaltung zuerst neue Einsendungen sichern und abgleichen. Keine
        automatische Rückmigration.
      </p>
      <a
        href="/settings"
        class="text-ui-accent-ink inline-flex min-h-6 items-center underline underline-offset-4"
        >Nach Prüfung und Quellentfernung migration.enabled deaktivieren</a
      >
    </div>
  </details>
  {#if probe}
    <form
      onsubmit={(e) => {
        e.preventDefault();
        void verifyProbe();
      }}
    >
      <FormSection title="Lokale Test-Entschlüsselung">
        <fieldset disabled={busy} class="m-0 grid min-w-0 gap-4 border-0 p-0">
          <p class="text-sm">
            Nur migrierte :2-HPKE-Proben. Alten privaten X25519-Datenschlüssel als Base64url
            eingeben. Er bleibt flüchtig im Browser; keine RSA-/CBC-Unterstützung.
          </p>
          <Row id="mig-private" label="Privater Altschlüssel">
            <Input
              id="mig-private"
              type="password"
              bind:value={privateKey}
              autocomplete="off"
              required
            />
          </Row>
          <div class="flex flex-wrap gap-2">
            <Button type="submit">Probe lokal entschlüsseln</Button>
            <Button
              type="button"
              variant="outline"
              onclick={() => {
                privateKey = '';
                probe = undefined;
              }}>Abbrechen</Button
            >
          </div>
        </fieldset>
      </FormSection>
    </form>
  {/if}
  <Panel>
    <div class="flex flex-col gap-3">
      <Row id="mig-delta" label="Neuer Snapshot-SHA256 für Delta-Prüflauf">
        <Input id="mig-delta" bind:value={deltaHash} pattern={'[0-9a-f]{64}'} class="font-mono" />
      </Row>
      <p class="text-muted-foreground text-sm">
        Delta benötigt eine neue eingefrorene Quelle gleicher Struktur und Zuordnung. Bestehende
        Quell-IDs und Zielnachweise werden geprüft; nur neue Quell-IDs werden angelegt. Änderungen
        sind Konflikte, Löschungen Prüfbedarf. Keine Freigabe für eine laufend veränderte Quelle.
      </p>
    </div>
  </Panel>
  <section class="flex flex-col gap-3">
    <h2 class="text-[length:var(--fs-h2)] leading-[26px] font-semibold">Fortschritt</h2>
    <p class="text-muted-foreground text-sm">
      Letzte Aktualisierung: {updated || 'Wird geladen …'}
    </p>
    {#if !jobs.length}
      <div class="surface-card text-muted-foreground px-5 py-6 text-center text-sm">
        Kein Umstieg gestartet.
      </div>
    {/if}
    {#each jobs as job (job.id)}
      <section aria-label={`Lauf ${job.id}`} class="surface-card flex flex-col gap-3 p-5">
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
          <h3 class="text-base font-semibold">
            {job.dryRun ? 'Prüflauf' : 'Import'}: {migrationStates[job.state] ?? job.state}
          </h3>
          <StatusChip
            tone={stateTones[job.state] ?? 'idle'}
            label={job.dryRun ? ui.steps.review : ui.steps.import}
            pulse={job.state === 'running'}
          />
        </div>
        <p role="status" class="text-sm">Phase: {job.phase}</p>
        <p class="text-muted-foreground text-sm">
          Lokale Probe: {job.probeConfirmed ? 'bestätigt' : 'offen'}; Testnachricht: {job.testConfirmed
            ? 'bestätigt'
            : 'offen'}
        </p>
        {#if job.state === 'running'}<progress aria-label="Import läuft" class="h-2 w-full"
          ></progress>{/if}
        {#if job.error}<p role="alert" class="text-danger text-sm">
            Phase {job.phase}: {job.error}. Zugang und Schema prüfen; denselben Lauf fortsetzen.
          </p>{/if}
        <details class="bg-surface-sunken rounded-md px-4 py-2">
          <summary class="min-h-6 cursor-pointer text-sm font-medium"
            >Probleme ansehen und bestätigte Zähler</summary
          >
          <pre class="mt-2 overflow-x-auto text-xs">{JSON.stringify(job.report, null, 2)}</pre>
        </details>
        <div class="flex flex-wrap gap-2">
          <Button variant="outline" onclick={() => download(job)}>Bericht herunterladen</Button>
          {#if ['queued', 'running'].includes(job.state)}<Button
              variant="outline"
              onclick={() => action(job.id, 'pause')}>Sicher pausieren</Button
            >{/if}
          {#if ['paused', 'failed'].includes(job.state)}<Button
              onclick={() => action(job.id, 'resume')}>Fortsetzen</Button
            >{/if}
          {#if job.state === 'review' && job.dryRun}<Button onclick={() => action(job.id, 'import')}
              >Import starten</Button
            >{/if}
          {#if job.state === 'review' && !job.dryRun}<Button
              variant="outline"
              disabled={busy}
              onclick={() => getProbe(job)}>Entschlüsselungsprobe laden</Button
            >
            <Button variant="outline" disabled={busy} onclick={() => delta(job)}
              >Delta-Prüflauf starten</Button
            >
            <Button variant="outline" onclick={() => convert(job)}
              >Entwürfe und Konverterbericht erstellen</Button
            >{/if}
          {#if ['review', 'paused', 'failed'].includes(job.state)}<Button
              variant="outline"
              onclick={() => action(job.id, 'remove-source')}>Altzugriff entfernen</Button
            >{/if}
        </div>
      </section>
    {/each}
  </section>
  <p class="text-muted-foreground text-sm">
    Import geprüft bedeutet keine Umschaltfreigabe. SDK vor DNS, finaler Delta-/Löschabgleich,
    Stichproben und Rückkehrplan müssen gesondert geprüft werden. Danach kann der Umstieg über
    migration.enabled deaktiviert werden.
  </p>
</div>
