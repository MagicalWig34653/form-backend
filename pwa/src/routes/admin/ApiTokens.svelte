<script lang="ts">
  import { onMount } from 'svelte';
  import { http } from '$lib/api';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';

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

<h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{text.title}</h1>
<p>{text.hint}</p>
{#if error}<p role="alert">{error}</p>{/if}
{#if consent}
  <div class="rounded border p-4">
    <h3>{oauthText.consent}</h3>
    <p>{oauthText.client}: {consent.clientName}</p>
    <p>{oauthText.host}: {consent.redirectHost}</p>
    <p>{oauthText.scopes}: {consent.scopes.join(', ')}</p>
    <p>{oauthText.boundary}</p>
    <label>{text.tenant}<Input bind:value={tenantId} required /></label>
    <label>{text.form}<Input bind:value={formId} /></label>
    <Button disabled={busy || !tenantId} onclick={() => void decide(true)}
      >{oauthText.approve}</Button
    >
    <Button disabled={busy} onclick={() => void decide(false)}>{oauthText.deny}</Button>
  </div>
{/if}
{#if secret}
  <div role="status" class="rounded border p-4">
    <p>{text.once}</p>
    <code class="break-all">{secret}</code>
    <Button
      onclick={() => {
        secret = '';
      }}>{text.hide}</Button
    >
  </div>
{/if}
<form onsubmit={create} class="flex max-w-xl flex-col gap-3">
  <label>{text.label}<Input bind:value={label} required maxlength={120} /></label>
  <label>{text.tenant}<Input bind:value={tenantId} required /></label>
  <label>{text.form}<Input bind:value={formId} /></label>
  <label>{text.days}<Input type="number" bind:value={days} min={1} max={90} required /></label>
  <label><input type="checkbox" bind:checked={read} /> {text.read}</label>
  <label><input type="checkbox" bind:checked={write} /> {text.write}</label>
  <Button type="submit" disabled={busy || (!read && !write)}>{text.create}</Button>
</form>
<ul class="flex flex-col gap-3">
  {#each items as item (item.id)}
    <li class="rounded border p-3">
      <strong>{item.label}</strong>
      <p>{text.expires}: {date(item.expires_at)} · {text.used}: {date(item.last_used_at)}</p>
      <p class="break-all">{item.scopes_json} · {item.scope_json}</p>
      {#if item.revoked_at != null}<span>{text.revoked}</span>
      {:else}<Button disabled={busy} onclick={() => void revoke(item.id)}>{text.revoke}</Button
        >{/if}
    </li>
  {/each}
</ul>

<section class="mt-8 flex flex-col gap-3">
  <h2 class="text-xl font-semibold">{oauthText.title}</h2>

  <ul>
    {#each grants as grant (grant.id)}
      <li class="rounded border p-3">
        <strong>{grant.clientName}</strong>
        <p class="break-all">{grant.clientId} · {grant.redirects}</p>
        <p class="break-all">{grant.scopes} · {grant.boundary}</p>
        {#if grant.revoked}<span>{text.revoked}</span>
        {:else}<Button onclick={() => void revokeGrant(grant.id)}>{text.revoke}</Button><Button
            onclick={() => void disconnectClient(grant.clientId)}>{oauthText.disconnect}</Button
          >{/if}
      </li>
    {/each}
  </ul>
</section>
