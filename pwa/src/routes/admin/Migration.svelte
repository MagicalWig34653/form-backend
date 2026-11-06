<script lang="ts">
  import { verifyMigrationProbe } from '$lib/crypto/migrationProbe';
  import { fromBase64Url } from '$lib/crypto/packageV2';
  import { onMount } from 'svelte';
  import { http, adminApi } from '$lib/api';
  import type { Tenant } from '$lib/api/admin';
  import { createImportPlan, migrationStates } from '$lib/setup';
  import { reauthenticate } from '$lib/admin/guard.svelte';
  import { needsFreshLogin } from '$lib/admin/describe';
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

<h1 id="page-title" tabindex="-1">Umstieg</h1>
<p>
  Nur lesender Zugriff auf einen isolierten, eingefrorenen Snapshot. Das Altsystem bleibt bis zur
  koordinierten Umschaltung führend.
</p>
<p>Quelle geprüft → Zuordnung → Import → Prüfung → Umschaltung</p>
<a href="/settings">Private Netze ausdrücklich unter migration.allowedNets freigeben</a>
{#if error}<p role="alert">{error}</p>
  <button onclick={load}>Erneut versuchen</button>{/if}
{#if notice}<p role="status">{notice}</p>{/if}
<form
  onsubmit={(e) => {
    e.preventDefault();
    void test();
  }}
>
  <fieldset disabled={busy}>
    <legend>Quelle – Nur lesender Zugriff</legend>
    <label>Host <input bind:value={host} required autocomplete="off" /></label>
    <label>Port <input type="number" min="1" max="65535" bind:value={port} required /></label>
    <label>Datenbank <input bind:value={database} required autocomplete="off" /></label>
    <label>Benutzer <input bind:value={username} required autocomplete="off" /></label>
    <label>Passwort <input type="password" bind:value={password} autocomplete="off" /></label>
    <label
      >TLS-Modus <select bind:value={tls}
        ><option value="verify">Zertifikat und Host prüfen</option><option value="disable"
          >Ohne TLS (nur freigegebene Entwicklungsumgebung)</option
        ></select
      ></label
    >
    <button>Verbindung prüfen</button>
  </fieldset>
</form>
{#if checkedSchema}<p role="status">
    Nur lesender Zugang geprüft. Schema-HMAC: <code>{checkedSchema}</code>
  </p>{/if}
{#if inventory}<details>
    <summary>Quellinventar und Formularzuordnung</summary>
    <pre>{JSON.stringify(inventory, null, 2)}</pre>
  </details>{/if}
<form
  onsubmit={(e) => {
    e.preventDefault();
    void start();
  }}
>
  <fieldset disabled={busy}>
    <legend>Inventar &amp; Zuordnung</legend>
    <label
      >Vorhandenen Kunden wählen <select
        onchange={(e) => {
          const selected = tenants.find((t) => t.id === e.currentTarget.value);
          if (selected) {
            customer = selected.id;
            name = selected.name;
          }
        }}
        ><option value="">Neuen Kunden zuordnen</option>{#each tenants as tenant (tenant.id)}<option
            value={tenant.id}>{tenant.name}</option
          >{/each}</select
      ></label
    >
    <p>
      Ein neuer Kunde wird inaktiv angelegt. Bei bestehenden Kunden muss der Name exakt zum
      gespeicherten Plan passen; vorhandene Fachobjekte werden nie überschrieben.
    </p>
    <label>Kunden-UUID (neu oder vorhanden) <input bind:value={customer} required /></label>
    <button type="button" onclick={() => (customer = crypto.randomUUID())}
      >Neue Kundenkennung</button
    >
    <label>Kundenname <input bind:value={name} required /></label>
    <label>Formular-UUIDs dieses Kunden <textarea bind:value={forms} required></textarea></label>
    <label>Quellnamespace <input bind:value={namespace} required /></label>
    <label
      >Dump-/Snapshot-SHA256 <input
        bind:value={snapshot}
        pattern={'[0-9a-f]{64}'}
        required
      /></label
    >
    <label
      >Erwarteter Schema-HMAC (bewusst aus der Quellprüfung übernehmen) <input
        bind:value={expectedSchema}
        pattern={'[0-9a-f]{64}'}
        required
      /></label
    >
    <label
      >Weitere bestätigte Planangaben als JSON (Verbindungen, Statistikbericht und öffentliche
      Schlüssel) <textarea bind:value={extra}></textarea></label
    >
    {#each assignments as mapping, index (index)}<p>{mapping.name}: {mapping.forms}</p>{/each}
    <button
      type="button"
      onclick={() => {
        assignments = [...assignments, { customer, name, forms }];
        customer = '';
        name = '';
        forms = '';
      }}>Weitere Kunden-/Formularzuordnung hinzufügen</button
    >
    <button>Prüflauf starten</button>
  </fieldset>
</form>
<h2>Abbruch und Rückkehrplan</h2>
<p>
  Pause stoppt an der nächsten Objektgrenze; bestätigte Importe bleiben erhalten. Der Prüflauf wird
  vollständig zurückgerollt. Altzugriff entfernen löscht Zugangsdaten, keine importierten
  Einsendungen. Für einen vollständigen Rollback vor Umschaltung die gesicherte Ziel-Datenbank
  wiederherstellen; nach Umschaltung zuerst neue Einsendungen sichern und abgleichen. Keine
  automatische Rückmigration.
</p>
<a href="/settings">Nach Prüfung und Quellentfernung migration.enabled deaktivieren</a>
{#if probe}
  <form
    onsubmit={(e) => {
      e.preventDefault();
      void verifyProbe();
    }}
  >
    <fieldset disabled={busy}>
      <legend>Lokale Test-Entschlüsselung</legend>
      <p>
        Nur migrierte :2-HPKE-Proben. Alten privaten X25519-Datenschlüssel als Base64url eingeben.
        Er bleibt flüchtig im Browser; keine RSA-/CBC-Unterstützung.
      </p>
      <label
        >Privater Altschlüssel <input
          type="password"
          bind:value={privateKey}
          autocomplete="off"
          required
        /></label
      >
      <button>Probe lokal entschlüsseln</button>
      <button
        type="button"
        onclick={() => {
          privateKey = '';
          probe = undefined;
        }}>Abbrechen</button
      >
    </fieldset>
  </form>
{/if}
<label
  >Neuer Snapshot-SHA256 für Delta-Prüflauf <input
    bind:value={deltaHash}
    pattern={'[0-9a-f]{64}'}
  /></label
>
<p>
  Delta benötigt eine neue eingefrorene Quelle gleicher Struktur und Zuordnung. Bestehende Quell-IDs
  und Zielnachweise werden geprüft; nur neue Quell-IDs werden angelegt. Änderungen sind Konflikte,
  Löschungen Prüfbedarf. Keine Freigabe für eine laufend veränderte Quelle.
</p>
<h2>Fortschritt</h2>
<p>Letzte Aktualisierung: {updated || 'Wird geladen …'}</p>
{#if !jobs.length}<p>Kein Umstieg gestartet.</p>{/if}
{#each jobs as job (job.id)}
  <section aria-label={`Lauf ${job.id}`}>
    <h3>{job.dryRun ? 'Prüflauf' : 'Import'}: {migrationStates[job.state] ?? job.state}</h3>
    <p role="status">Phase: {job.phase}</p>
    <p>
      Lokale Probe: {job.probeConfirmed ? 'bestätigt' : 'offen'}; Testnachricht: {job.testConfirmed
        ? 'bestätigt'
        : 'offen'}
    </p>
    {#if job.state === 'running'}<progress aria-label="Import läuft"></progress>{/if}
    {#if job.error}<p role="alert">
        Phase {job.phase}: {job.error}. Zugang und Schema prüfen; denselben Lauf fortsetzen.
      </p>{/if}
    <details>
      <summary>Probleme ansehen und bestätigte Zähler</summary>
      <pre>{JSON.stringify(job.report, null, 2)}</pre>
    </details>
    <button onclick={() => download(job)}>Bericht herunterladen</button>
    {#if ['queued', 'running'].includes(job.state)}<button onclick={() => action(job.id, 'pause')}
        >Sicher pausieren</button
      >{/if}
    {#if ['paused', 'failed'].includes(job.state)}<button onclick={() => action(job.id, 'resume')}
        >Fortsetzen</button
      >{/if}
    {#if job.state === 'review' && job.dryRun}<button onclick={() => action(job.id, 'import')}
        >Import starten</button
      >{/if}
    {#if job.state === 'review' && !job.dryRun}<button disabled={busy} onclick={() => getProbe(job)}
        >Entschlüsselungsprobe laden</button
      >
      <button disabled={busy} onclick={() => delta(job)}>Delta-Prüflauf starten</button>
      <button onclick={() => convert(job)}>Entwürfe und Konverterbericht erstellen</button>{/if}
    {#if ['review', 'paused', 'failed'].includes(job.state)}<button
        onclick={() => action(job.id, 'remove-source')}>Altzugriff entfernen</button
      >{/if}
  </section>
{/each}
<p>
  Import geprüft bedeutet keine Umschaltfreigabe. SDK vor DNS, finaler Delta-/Löschabgleich,
  Stichproben und Rückkehrplan müssen gesondert geprüft werden. Danach kann der Umstieg über
  migration.enabled deaktiviert werden.
</p>
