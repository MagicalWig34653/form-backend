<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { Connection, JsonObject } from '$lib/api/admin';
  import { session } from '$lib/session.svelte';
  import { onboarding } from '$lib/onboarding.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { deriveCheck, type CheckOutcome } from '$lib/admin/connectionCheck';
  import ConnectionCheck from '$lib/components/admin/ConnectionCheck.svelte';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import RowMenu from '$lib/components/admin/RowMenu.svelte';
  import { Dialog, DialogContent, DialogClose } from '$lib/components/ui/dialog';
  import { formatClock } from '$lib/format';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';

  let items = $state<Connection[] | null>(null);
  let loadError = $state('');
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  // Kommt der Nutzer aus der Einrichtung (Schritt Mail-Versandweg), ist das Formular sofort offen.
  let showCreate = $state(onboarding.activeContext === 'mail');
  let assigned = $state<Record<string, string[]> | null>(null);
  let tested = $state<Record<string, { ok: boolean; at: Date }>>({});
  interface CheckState {
    running: boolean;
    outcome: CheckOutcome | null;
    error: string;
    ms: number | null;
  }
  let checks = $state<Record<string, CheckState>>({});
  let assignFor = $state<Connection | null>(null);
  let picked = $state<string[]>([]);

  let kind = $state<'smtp' | 'mail-proxy'>('smtp');
  let name = $state('');
  let host = $state('');
  let port = $state('587');
  let security = $state<'tls' | 'starttls' | 'plain'>('starttls');
  let username = $state('');
  let secret = $state('');
  let url = $state('');
  // Entscheidung 0044: je Verbindung ausdrücklich wählbar, nie voreingestellt.
  let allowSelfSigned = $state(false);

  async function load(): Promise<void> {
    loadError = '';
    const r = await adminApi.connections();
    if (r.ok) {
      items = r.data.items;
      void loadAssigned();
    } else if (!handleSessionError(r.error))
      loadError =
        r.error.kind === 'http' && r.error.status === 403
          ? t.admin.connections.forbidden
          : describeError(r.error);
  }

  /** Which customers use which connection; unknown (null) when a customer cannot be read. */
  async function loadAssigned(): Promise<void> {
    const result: Record<string, string[]> = {};
    const lists = await Promise.all(
      session.tenants.map(async (tenant) => ({
        tenant,
        r: await adminApi.tenantConnections(tenant.id),
      })),
    );
    for (const { tenant, r } of lists) {
      if (!r.ok) {
        assigned = null;
        return;
      }
      for (const c of r.data.items) (result[c.id] ??= []).push(tenant.name);
    }
    assigned = result;
  }

  /** Runs a call; a stale login sends the user through login and back, other failures are shown. */
  async function run<T>(
    call: () => Promise<
      { ok: true; data: T } | { ok: false; error: Parameters<typeof describeError>[0] }
    >,
    success: string,
  ): Promise<T | null> {
    if (busy) return null;
    busy = true;
    message = ok = '';
    const r = await call();
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) {
        message = t.admin.connections.freshHint;
        await reauthenticate('/connections');
      } else if (!handleSessionError(r.error)) message = describeError(r.error);
      return null;
    }
    ok = success;
    return r.data;
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const config: JsonObject =
      kind === 'smtp'
        ? {
            host: host.trim(),
            port: Number(port),
            security,
            ...(username.trim() ? { username: username.trim() } : {}),
            ...(allowSelfSigned && security !== 'plain' ? { verifyCertificate: false } : {}),
          }
        : { url: url.trim() };
    const body = { kind, name: name.trim(), config, ...(secret ? { credential: secret } : {}) };
    const created = await run(() => adminApi.createConnection(body), t.admin.connections.created);
    if (created) {
      name = host = username = secret = url = '';
      allowSelfSigned = false;
      showCreate = false;
      await load();
    }
  }

  async function test(c: Connection): Promise<void> {
    if (busy || checks[c.id]?.running) return;
    busy = true;
    message = ok = '';
    checks[c.id] = { running: true, outcome: null, error: '', ms: null };
    const started = performance.now();
    const r = await adminApi.testConnection(c.id);
    const ms = performance.now() - started;
    busy = false;
    if (!r.ok) {
      delete checks[c.id];
      if (needsFreshLogin(r.error)) {
        message = t.admin.connections.freshHint;
        await reauthenticate('/connections');
      } else if (!handleSessionError(r.error)) {
        const error =
          r.error.kind === 'http' && r.error.status === 429
            ? t.admin.connections.check.rateLimited
            : describeError(r.error);
        checks[c.id] = { running: false, outcome: null, error, ms: null };
      }
      return;
    }
    tested[c.id] = { ok: r.data.ok, at: new Date() };
    checks[c.id] = { running: false, outcome: deriveCheck(c.kind, r.data), error: '', ms };
  }

  /** Wieder prüfen: die sichere Richtung braucht keine Rückfrage. */
  async function verifyAgain(c: Connection): Promise<void> {
    const done = await run(
      () => adminApi.setTlsVerification(c.id, true),
      t.admin.connections.verifyAgainDone,
    );
    if (done !== null || !message) await load();
  }
  async function setEnabled(c: Connection, enabled: boolean): Promise<void> {
    const done = await run(
      () => adminApi.setConnectionEnabled(c.id, enabled),
      enabled ? t.admin.connections.enableDone : t.admin.connections.disableDone,
    );
    if (done !== null || !message) await load();
  }
  const unverified = (c: Connection): boolean =>
    c.kind === 'smtp' && (c.config as { verifyCertificate?: unknown }).verifyCertificate === false;

  function openAssign(c: Connection): void {
    assignFor = c;
    picked = [];
  }
  const taken = (c: Connection, tenantName: string): boolean =>
    !!assigned?.[c.id]?.includes(tenantName);

  async function assign(): Promise<void> {
    const c = assignFor;
    if (!c || picked.length === 0) return;
    for (const tenant of picked) {
      const done = await run(
        () => adminApi.assignConnection(tenant, c.id),
        t.admin.connections.assigned,
      );
      if (done === null && message) return;
    }
    assignFor = null;
    await loadAssigned();
  }

  const hostOf = (c: Connection): string => {
    const config = c.config as { host?: unknown; url?: unknown };
    if (typeof config.host === 'string') return config.host;
    if (typeof config.url === 'string') {
      try {
        return new URL(config.url).hostname;
      } catch {
        return config.url;
      }
    }
    return '';
  };

  onMount(() => void load());
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader
    title={t.admin.connections.title}
    description={t.admin.connections.intro}
    compactActions
  >
    {#snippet actions()}
      {#if items !== null && !loadError && !showCreate}<Button onclick={() => (showCreate = true)}
          >{t.admin.connections.create}</Button
        >{/if}
    {/snippet}
  </PageHeader>
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />

  {#if loadError}
    <Banner tone="danger">
      {loadError}
      {#snippet action()}
        <Button variant="outline" onclick={() => void load()}>{t.lists.retry}</Button>
      {/snippet}
    </Banner>
  {:else if items === null}
    <div aria-busy="true" class="flex flex-col gap-3">
      <span class="sr-only" role="status">{t.admin.loading}</span>
      <Skeleton class="h-20" /><Skeleton class="h-20" />
    </div>
  {:else if items.length === 0}
    <Panel>
      <EmptyState
        title={t.admin.connections.none}
        description={t.admin.connections.noneHint}
        icon="connections"
      >
        {#snippet action()}
          <Button onclick={() => (showCreate = true)}>{t.admin.connections.create}</Button>
        {/snippet}
      </EmptyState>
    </Panel>
  {:else}
    <Panel flush>
      <ul class="divide-border m-0 flex list-none flex-col divide-y p-0">
        {#each items as c (c.id)}
          {@const result = tested[c.id]}
          {@const check = checks[c.id]}
          {@const names = assigned?.[c.id]}
          <li class="flex flex-wrap items-center gap-x-4 gap-y-3 px-5 py-4">
            <div class="min-w-0 flex-1 basis-64">
              <p class="m-0 font-medium">{c.name}</p>
              <p class="text-muted-foreground m-0 text-sm">
                {t.admin.connections.kinds[c.kind]}{hostOf(c)
                  ? ' · ' + hostOf(c)
                  : ''}{c.hasCredential ? ' · ' + t.admin.connections.hasCredential : ''}
              </p>
              {#if assigned !== null}<p class="text-muted-foreground m-0 text-sm">
                  {names?.length
                    ? t.admin.connections.assignedTo.replace('{names}', names.join(', '))
                    : t.admin.connections.assignedNone}
                </p>{/if}
            </div>
            <div class="flex flex-wrap items-center gap-2">
              {#if unverified(c)}<StatusChip
                  tone="warn"
                  label={t.admin.connections.unverified}
                />{/if}
              {#if !c.enabled}<StatusChip tone="idle" label={t.admin.connections.disabled} />{/if}
              {#if result?.ok}<StatusChip
                  tone="ok"
                  label={t.admin.connections.tested.replace('{time}', formatClock(result.at))}
                />{:else if result}<StatusChip
                  tone="danger"
                  label={t.admin.connections.testFailedChip}
                />{:else}<StatusChip
                  tone={names?.length && c.enabled ? 'warn' : 'idle'}
                  label={t.admin.connections.untested}
                />{/if}
              <Button type="button" variant="outline" disabled={busy} onclick={() => void test(c)}
                >{checks[c.id]?.running
                  ? t.admin.connections.check.running
                  : check
                    ? t.admin.connections.check.again
                    : t.admin.connections.test}<span class="sr-only"> {c.name}</span></Button
              >
              <RowMenu
                label={t.admin.connections.rowActions.replace('{name}', c.name)}
                disabled={busy}
                items={[
                  {
                    id: 'assign',
                    label: t.admin.connections.assign,
                    onselect: () => openAssign(c),
                  },
                  {
                    id: c.enabled ? 'disable' : 'enable',
                    label: c.enabled ? t.admin.connections.disable : t.admin.connections.enable,
                    onselect: () => void setEnabled(c, !c.enabled),
                  },
                  ...(unverified(c)
                    ? [
                        {
                          id: 'verify',
                          label: t.admin.connections.verifyAgain,
                          onselect: () => void verifyAgain(c),
                        },
                      ]
                    : []),
                ]}
              />
            </div>
            {#if check}
              <ConnectionCheck
                id={c.id}
                kind={c.kind}
                name={c.name}
                running={check.running}
                outcome={check.outcome}
                error={check.error}
                totalMs={check.ms}
              />
            {/if}
          </li>
        {/each}
      </ul>
    </Panel>
  {/if}

  {#if showCreate}
    <Panel title={t.admin.connections.create} description={t.admin.connections.freshHint}>
      <form onsubmit={(e) => void create(e)} class="flex max-w-[560px] flex-col gap-4">
        <Row id="conn-kind" label={t.admin.connections.kind}>
          <Select id="conn-kind" bind:value={kind}>
            <option value="smtp">{t.admin.connections.kinds.smtp}</option>
            <option value="mail-proxy">{t.admin.connections.kinds['mail-proxy']}</option>
          </Select>
        </Row>
        <Row id="conn-name" label={t.admin.connections.name}
          ><Input
            id="conn-name"
            bind:value={name}
            required
            maxlength={190}
            autocomplete="off"
          /></Row
        >
        {#if kind === 'smtp'}
          <Row id="conn-host" label={t.admin.connections.host}
            ><Input
              id="conn-host"
              bind:value={host}
              required
              autocomplete="off"
              spellcheck={false}
            /></Row
          >
          <Row id="conn-port" label={t.admin.connections.port}
            ><Input
              id="conn-port"
              type="number"
              min="1"
              max="65535"
              bind:value={port}
              required
            /></Row
          >
          <Row id="conn-security" label={t.admin.connections.security}>
            <Select id="conn-security" bind:value={security}>
              {#each ['tls', 'starttls', 'plain'] as s (s)}<option value={s}
                  >{t.admin.connections.securities[s as 'tls']}</option
                >{/each}
            </Select>
          </Row>
          {#if security !== 'plain'}
            <div class="flex flex-col gap-2">
              <label class="flex min-h-11 items-center gap-3 text-sm">
                <input
                  id="conn-selfsigned"
                  type="checkbox"
                  class="size-5 accent-[var(--ui-accent)]"
                  bind:checked={allowSelfSigned}
                />
                <span>{t.admin.connections.allowSelfSigned}</span>
              </label>
              {#if allowSelfSigned}<Banner tone="warn"
                  >{t.admin.connections.selfSignedWarning}</Banner
                >{/if}
            </div>
          {/if}
          <Row id="conn-user" optional label={t.admin.connections.username}
            ><Input id="conn-user" bind:value={username} autocomplete="off" /></Row
          >
          <Row
            id="conn-secret"
            optional={username.trim() === ''}
            label={t.admin.connections.password}
            ><Input
              id="conn-secret"
              type="password"
              bind:value={secret}
              autocomplete="new-password"
              required={username.trim() !== ''}
            /></Row
          >
        {:else}
          <Row id="conn-url" label={t.admin.connections.url}
            ><Input id="conn-url" type="url" bind:value={url} required autocomplete="off" /></Row
          >
          <Row id="conn-secret" label={t.admin.connections.acode}
            ><Input
              id="conn-secret"
              type="password"
              bind:value={secret}
              autocomplete="new-password"
              required
            /></Row
          >
        {/if}
        <div class="flex gap-2">
          <Button type="submit" disabled={busy}>{t.admin.connections.create}</Button>
          <Button type="button" variant="ghost" onclick={() => (showCreate = false)}
            >{t.admin.cancel}</Button
          >
        </div>
      </form>
    </Panel>
  {/if}
  <Dialog
    open={assignFor !== null}
    onOpenChange={(value) => {
      if (!value) assignFor = null;
    }}
  >
    {#if assignFor}
      <DialogContent
        title={t.admin.connections.assign}
        description={t.admin.connections.assignDescription.replace('{name}', assignFor.name)}
      >
        <ul class="m-0 flex w-full list-none flex-col gap-1 p-0">
          {#each session.tenants as tenant (tenant.id)}
            {@const already = taken(assignFor, tenant.name)}
            <li>
              <label class="flex min-h-11 items-center gap-3 text-sm">
                <input
                  type="checkbox"
                  class="size-5 accent-[var(--ui-accent)]"
                  value={tenant.id}
                  bind:group={picked}
                  disabled={already || busy}
                  checked={already || undefined}
                />
                <span>{tenant.name}</span>
                {#if already}<span class="text-muted-foreground"
                    >{t.admin.connections.alreadyAssigned}</span
                  >{/if}
              </label>
            </li>
          {/each}
        </ul>
        <DialogClose>
          {#snippet child({ props })}
            <Button {...props} variant="ghost" type="button">{t.admin.cancel}</Button>
          {/snippet}
        </DialogClose>
        <Button type="button" disabled={busy || picked.length === 0} onclick={() => void assign()}
          >{t.admin.connections.assignConfirm}</Button
        >
      </DialogContent>
    {/if}
  </Dialog>
</div>
