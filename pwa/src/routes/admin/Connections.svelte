<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { Connection, JsonObject } from '$lib/api/admin';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';

  let items = $state<Connection[] | null>(null);
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  let assignTo = $state<Record<string, string>>({});

  let kind = $state<'smtp' | 'mail-proxy'>('smtp');
  let name = $state('');
  let host = $state('');
  let port = $state('587');
  let security = $state<'tls' | 'starttls' | 'plain'>('starttls');
  let username = $state('');
  let secret = $state('');
  let url = $state('');

  async function load(): Promise<void> {
    const r = await adminApi.connections();
    if (r.ok) items = r.data.items;
    else if (!handleSessionError(r.error)) message = describeError(r.error);
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
          }
        : { url: url.trim() };
    const body = { kind, name: name.trim(), config, ...(secret ? { credential: secret } : {}) };
    const created = await run(() => adminApi.createConnection(body), t.admin.connections.created);
    if (created) {
      name = host = username = secret = url = '';
      await load();
    }
  }

  async function test(id: string): Promise<void> {
    const res = await run(() => adminApi.testConnection(id), '');
    if (!res) return;
    if (res.ok) ok = t.admin.connections.testOk;
    else message = t.admin.connections.testFailed.replace('{code}', res.code ?? '?');
  }

  async function assign(id: string): Promise<void> {
    const tenant = assignTo[id];
    if (!tenant) return;
    await run(() => adminApi.assignConnection(tenant, id), t.admin.connections.assigned);
  }

  onMount(() => void load());
</script>

<div class="flex w-full max-w-[820px] flex-col gap-6">
  <PageHeader title={t.admin.connections.title} description={t.admin.connections.intro} />
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />

  {#if items === null}
    <div aria-busy="true" class="flex flex-col gap-3">
      <span class="sr-only" role="status">{t.admin.loading}</span>
      <Skeleton class="h-20" /><Skeleton class="h-20" />
    </div>
  {:else if items.length === 0}
    <div class="bg-card ring-1 ring-foreground/10 rounded-xl">
      <EmptyState title={t.admin.connections.none} icon="connections" />
    </div>
  {:else}
    <ul class="flex flex-col gap-3">
      {#each items as c (c.id)}
        <li class="bg-card ring-1 ring-foreground/10 rounded-xl flex flex-col gap-3 px-5 py-4">
          <div class="flex flex-wrap items-baseline justify-between gap-2">
            <span class="font-medium">{c.name}</span>
            <span class="text-muted-foreground flex flex-wrap items-center gap-2 text-sm"
              >{t.admin.connections.kinds[c.kind]}{c.hasCredential
                ? ' · ' + t.admin.connections.hasCredential
                : ''}{#if !c.enabled}<StatusChip
                  tone="idle"
                  label={t.admin.connections.disabled}
                />{/if}</span
            >
          </div>
          <div class="flex flex-wrap items-end gap-2">
            <Button type="button" variant="outline" disabled={busy} onclick={() => void test(c.id)}
              >{t.admin.connections.test}<span class="sr-only"> {c.name}</span></Button
            >
            <label class="flex flex-col gap-1 text-sm">
              <span class="sr-only">{t.admin.connections.assign} {c.name}</span>
              <Select
                bind:value={assignTo[c.id]}
                aria-label={`${t.admin.connections.assign}: ${c.name}`}
              >
                <option value={undefined} disabled selected>{t.admin.connections.assign}</option>
                {#each session.tenants as tenant (tenant.id)}<option value={tenant.id}
                    >{tenant.name}</option
                  >{/each}
              </Select>
            </label>
            <Button
              type="button"
              variant="outline"
              disabled={busy || !assignTo[c.id]}
              onclick={() => void assign(c.id)}>{t.admin.connections.assign}</Button
            >
          </div>
        </li>
      {/each}
    </ul>
  {/if}

  <Panel title={t.admin.connections.create} description={t.admin.connections.freshHint}>
    <form onsubmit={(e) => void create(e)} class="flex max-w-md flex-col gap-4">
      <Row id="conn-kind" label={t.admin.connections.kind}>
        <Select id="conn-kind" bind:value={kind}>
          <option value="smtp">{t.admin.connections.kinds.smtp}</option>
          <option value="mail-proxy">{t.admin.connections.kinds['mail-proxy']}</option>
        </Select>
      </Row>
      <Row id="conn-name" label={t.admin.connections.name}
        ><Input id="conn-name" bind:value={name} required maxlength={190} autocomplete="off" /></Row
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
        <Row id="conn-user" label={t.admin.connections.username}
          ><Input id="conn-user" bind:value={username} autocomplete="off" /></Row
        >
        <Row id="conn-secret" label={t.admin.connections.password}
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
      <div><Button type="submit" disabled={busy}>{t.admin.connections.create}</Button></div>
    </form>
  </Panel>
</div>
