<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';

  interface Token {
    id: string;
    label: string;
    expires_at: number;
    last_used_at: number | null;
    revoked_at: number | null;
    scopes_json: string;
    scope_json: string;
  }
  interface OAuthGrant {
    id: string;
    clientName: string;
    clientId: string;
    redirects: string;
    scopes: string;
    boundary: string;
    revoked: boolean;
  }
  interface Consent {
    clientName: string;
    redirectHost: string;
    scopes: string[];
  }
  let grants = $state<OAuthGrant[]>([]);
  let consent = $state<Consent | null>(null);
  const requestId = new URLSearchParams(window.location.search).get('oauth_request');
  const oauthText = t.admin.oauth;
  async function loadOAuth() {
    const r = await http.request<{ items: OAuthGrant[] }>('GET', '/account/oauth');
    if (r.ok) grants = r.data.items;
    else await failure(r.error);
    if (requestId) {
      const c = await http.request<Consent>(
        'GET',
        `/account/oauth/requests/${encodeURIComponent(requestId)}`,
      );
      if (c.ok) consent = c.data;
      else await failure(c.error);
    }
  }
  async function decide(approve: boolean) {
    if (busy || !requestId) return;
    busy = true;
    const r = await http.request<{ redirect: string }>('POST', '/account/oauth/consent', {
      body: { requestId, approve, ...(approve ? { tenantId, ...(formId ? { formId } : {}) } : {}) },
    });
    if (r.ok) window.location.assign(r.data.redirect);
    else await failure(r.error);
    busy = false;
  }
  async function disconnectClient(client: string) {
    const r = await http.request('DELETE', `/account/oauth/clients/${encodeURIComponent(client)}`);
    if (r.ok) await loadOAuth();
    else await failure(r.error);
  }
  async function revokeGrant(id: string) {
    const r = await http.request('DELETE', `/account/oauth/${id}`);
    if (r.ok) await loadOAuth();
    else await failure(r.error);
  }
  let items = $state<Token[]>([]);
  let label = $state('');
  let tenantId = $state('');
  let formId = $state('');
  let days = $state(30);
  let read = $state(true);
  let write = $state(false);
  let secret = $state('');
  let error = $state('');
  let busy = $state(false);
  const text = t.admin.tokens;

  async function failure(e: Parameters<typeof describeError>[0]) {
    if (needsFreshLogin(e)) await reauthenticate('/api-tokens');
    else if (!handleSessionError(e))
      error =
        e.kind === 'http' && e.status === 403
          ? `${describeError(e)} ${text.mcpNotAllowed}`
          : describeError(e);
  }
  async function load() {
    const r = await http.request<{ items: Token[] }>('GET', '/account/tokens');
    if (r.ok) items = r.data.items;
    else await failure(r.error);
  }
  async function create(e: SubmitEvent) {
    e.preventDefault();
    if (busy) return;
    busy = true;
    error = '';
    secret = '';
    const scopes = [
      ...(read ? ['konfiguration.lesen'] : []),
      ...(write ? ['entwurf.schreiben'] : []),
    ];
    const r = await http.request<{ token: string }>('POST', '/account/tokens', {
      body: {
        label,
        tenantId,
        ...(formId ? { formId } : {}),
        scopes,
        expiresAt: new Date(Date.now() + days * 86400000).toISOString().replace(/\.\d{3}Z$/, 'Z'),
      },
    });
    if (r.ok) {
      secret = r.data.token;
      await load();
    } else await failure(r.error);
    busy = false;
  }
  async function revoke(id: string) {
    if (busy) return;
    busy = true;
    error = '';
    secret = '';
    const r = await http.request('DELETE', `/account/tokens/${id}`);
    if (r.ok) await load();
    else await failure(r.error);
    busy = false;
  }
  function date(value: number | null) {
    return value == null ? '—' : new Date((value + 978307200) * 1000).toLocaleString('de-DE');
  }
  onMount(() => {
    void load();
    void loadOAuth();
  });
</script>

<div class="mx-auto flex w-full max-w-[820px] flex-col gap-6">
  <PageHeader title={text.title} description={text.hint} />
  {#if error}<Banner tone="danger">{error}</Banner>{/if}
  {#if consent}
    <Panel title={oauthText.consent} level={3} class="border-warn/40">
      <div class="flex flex-col gap-4">
        <div class="grid gap-1 text-sm font-medium">
          <p>{oauthText.client}: {consent.clientName}</p>
          <p class="break-all">{oauthText.host}: {consent.redirectHost}</p>
          <p>{oauthText.scopes}: {consent.scopes.join(', ')}</p>
        </div>
        <p class="text-muted-foreground text-sm">{oauthText.boundary}</p>
        <div class="grid gap-4 sm:grid-cols-2">
          <Row id="consent-tenant" label={text.tenant}
            ><Input id="consent-tenant" bind:value={tenantId} required /></Row
          >
          <Row id="consent-form" label={text.form}
            ><Input id="consent-form" bind:value={formId} /></Row
          >
        </div>
        <div class="flex flex-wrap gap-2">
          <Button disabled={busy || !tenantId} onclick={() => void decide(true)}
            >{oauthText.approve}</Button
          >
          <Button variant="outline" disabled={busy} onclick={() => void decide(false)}
            >{oauthText.deny}</Button
          >
        </div>
      </div>
    </Panel>
  {/if}
  {#if secret}
    <div role="status" class="bg-ok-soft border-ok/30 rounded-[var(--r-card)] border p-5">
      <p class="font-medium">{text.once}</p>
      <code class="bg-surface-card my-3 block rounded-md px-3 py-2 break-all">{secret}</code>
      <Button
        variant="outline"
        onclick={() => {
          secret = '';
        }}>{text.hide}</Button
      >
    </div>
  {/if}
  <Panel title={t.formKit.tokens.newToken}>
    <form onsubmit={create} class="flex max-w-xl flex-col gap-4">
      <Row id="token-label" label={text.label}
        ><Input id="token-label" bind:value={label} required maxlength={120} /></Row
      >
      <Row id="token-tenant" label={text.tenant}
        ><Input id="token-tenant" bind:value={tenantId} required /></Row
      >
      <Row id="token-form" label={text.form}><Input id="token-form" bind:value={formId} /></Row>
      <Row id="token-days" label={text.days}
        ><Input id="token-days" type="number" bind:value={days} min={1} max={90} required /></Row
      >
      <fieldset class="flex flex-col gap-1">
        <legend class="sr-only">{t.formKit.tokens.scopes}</legend>
        <label class="flex min-h-8 items-center gap-2 text-sm"
          ><Checkbox bind:checked={read} /> {text.read}</label
        >
        <label class="flex min-h-8 items-center gap-2 text-sm"
          ><Checkbox bind:checked={write} /> {text.write}</label
        >
      </fieldset>
      <div><Button type="submit" disabled={busy || (!read && !write)}>{text.create}</Button></div>
    </form>
  </Panel>
  {#if items.length}
    <ul class="flex flex-col gap-3">
      {#each items as item (item.id)}
        <li class="surface-card flex flex-col gap-2 px-5 py-4">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <strong>{item.label}</strong>
            {#if item.revoked_at != null}<StatusChip tone="idle" label={text.revoked} />
            {:else}<Button variant="outline" disabled={busy} onclick={() => void revoke(item.id)}
                >{text.revoke}</Button
              >{/if}
          </div>
          <p class="text-muted-foreground text-sm">
            {text.expires}: {date(item.expires_at)} · {text.used}: {date(item.last_used_at)}
          </p>
          <p class="text-muted-foreground font-mono text-xs break-all">
            {item.scopes_json} · {item.scope_json}
          </p>
        </li>
      {/each}
    </ul>
  {/if}

  <section class="flex flex-col gap-3">
    <h2 class="text-[length:var(--fs-h2)] font-semibold">{oauthText.title}</h2>
    {#if grants.length}
      <ul class="flex flex-col gap-3">
        {#each grants as grant (grant.id)}
          <li class="surface-card flex flex-col gap-2 px-5 py-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <strong>{grant.clientName}</strong>
              {#if grant.revoked}<StatusChip tone="idle" label={text.revoked} />{/if}
            </div>
            <p class="text-muted-foreground text-sm break-all">
              {grant.clientId} · {grant.redirects}
            </p>
            <p class="text-muted-foreground text-sm break-all">{grant.scopes} · {grant.boundary}</p>
            {#if !grant.revoked}
              <div class="flex flex-wrap gap-2">
                <Button variant="outline" onclick={() => void revokeGrant(grant.id)}
                  >{text.revoke}</Button
                ><Button variant="outline" onclick={() => void disconnectClient(grant.clientId)}
                  >{oauthText.disconnect}</Button
                >
              </div>
            {/if}
          </li>
        {/each}
      </ul>
    {:else}
      <div class="surface-card"><EmptyState title={t.formKit.tokens.noGrants} icon="tokens" /></div>
    {/if}
  </section>
</div>
