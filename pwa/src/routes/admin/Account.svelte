<script lang="ts">
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import KeyringPanel from './KeyringPanel.svelte';
  import RotationPanel from './RotationPanel.svelte';
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { authApi, adminApi, http } from '$lib/api';
  import type { PasskeyInfo } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';

  const a = t.admin.account;
  const c = t.accountsPackage;
  let totpEnabled = $state(false);
  let totpSecret = $state('');
  let totpCode = $state('');
  let totpPassword = $state('');
  async function changeTotp(method: 'POST' | 'PUT' | 'DELETE'): Promise<void> {
    if (busy) return;
    busy = true;
    message = ok = '';
    const r = await http.request<{ secret?: string }>(method, '/me/totp', {
      body:
        method === 'PUT'
          ? { code: totpCode }
          : method === 'DELETE'
            ? { password: totpPassword }
            : {},
    });
    totpCode = totpPassword = '';
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) message = describeError(r.error);
      return;
    }
    if (method === 'POST') totpSecret = r.data.secret ?? '';
    else {
      totpSecret = '';
      ok = c.saved;
      await load();
    }
  }
  $effect(() => () => {
    totpSecret = totpCode = totpPassword = '';
  });
  let customerKids = $state<Record<string, string | null>>({});
  let keys = $state<PasskeyInfo[]>([]);
  let loaded = $state(false);
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  let username = $state('');
  let password = $state('');
  let link = $state('');
  let secondFactorRequired = $state(false);
  let showPassword = $state(false);
  let ownPassword = $state('');

  async function savePassword(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    message = ok = '';
    const r = await adminApi.setPassword(ownPassword);
    ownPassword = '';
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) message = describeError(r.error);
      return;
    }
    ok = a.passwordSaved;
    showPassword = false;
  }

  async function load(): Promise<void> {
    const state = await http.request<{ enabled: boolean }>('GET', '/me/totp');
    if (state.ok) totpEnabled = state.data.enabled;
    const policy = await authApi.session();
    if (policy.ok) secondFactorRequired = policy.data.secondFactorRequired ?? true;
    const r = await adminApi.passkeys();
    if (r.ok) keys = r.data.items;
    else if (!handleSessionError(r.error)) message = describeError(r.error);
    for (const tenant of session.tenants) {
      const key = await adminApi.customerKey(tenant.id);
      if (key.ok) customerKids[tenant.id] = key.data.keyId;
    }
    loaded = true;
  }

  async function remove(k: PasskeyInfo): Promise<void> {
    if (busy) return;
    if (k.unlocksKeys && !confirm(a.removeWarn)) return;
    busy = true;
    message = ok = '';
    const r = await adminApi.removePasskey(k.credentialId);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error))
        message = r.error.status === 422 ? a.lastOne : describeError(r.error);
      return;
    }
    ok = a.removed;
    await load();
  }

  async function create(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (busy) return;
    busy = true;
    message = ok = link = '';
    const r = await adminApi.createAccount(username.trim(), password);
    busy = false;
    password = '';
    if (!r.ok) {
      if (needsFreshLogin(r.error)) return void (await reauthenticate(router.path));
      if (!handleSessionError(r.error)) message = r.error.status === 409 ? a.exists : a.failed;
      return;
    }
    username = '';
    link = r.data.setupLink;
  }

  // The one-time link must not outlive this view.
  $effect(() => () => {
    link = '';
  });
  onMount(() => void load());
</script>

<section class="flex flex-col gap-4">
  <h1 id="page-title" tabindex="-1" class="text-2xl font-semibold">{a.title}</h1>
  <h2 class="text-lg font-medium">{t.access.security}</h2>
  <AccessStatus />
  <RecoveryStep security />
  <details>
    <summary>{t.access.advanced}</summary>
    {#each session.tenants as tenant (tenant.id)}
      <h3>{tenant.name}</h3>
      <KeyringPanel
        tenant={tenant.id}
        keyId={customerKids[tenant.id] ?? null}
        onchange={() => void load()}
      />
      <RotationPanel tenant={tenant.id} onchange={() => {}} />
    {/each}
  </details>
  <h2 class="text-lg font-medium">{c.totp}</h2>
  <p class="max-w-prose text-sm">{c.totpHint}</p>
  <p>{totpEnabled ? c.enabled : c.disabled}</p>
  {#if !totpEnabled}
    <Button type="button" variant="outline" disabled={busy} onclick={() => void changeTotp('POST')}
      >{c.setup}</Button
    >
    {#if totpSecret}
      <p class="max-w-prose text-sm">{c.setupHint}</p>
      <p class="font-mono select-all">{totpSecret}</p>
      <form
        onsubmit={(e) => {
          e.preventDefault();
          void changeTotp('PUT');
        }}
        class="flex max-w-xl flex-col gap-3"
      >
        <Row id="totp-code" label={c.code}
          ><Input
            id="totp-code"
            bind:value={totpCode}
            inputmode="numeric"
            pattern={'[0-9]{6}'}
            maxlength={6}
            autocomplete="one-time-code"
            required
          /></Row
        >
        <Button type="submit" disabled={busy}>{c.confirm}</Button>
      </form>
    {/if}
  {:else}
    <form
      onsubmit={(e) => {
        e.preventDefault();
        void changeTotp('DELETE');
      }}
      class="flex max-w-xl flex-col gap-3"
    >
      <Row id="totp-password" label={c.password}
        ><Input
          id="totp-password"
          type="password"
          bind:value={totpPassword}
          autocomplete="current-password"
          required
        /></Row
      >
      <Button type="submit" variant="outline" disabled={busy}>{c.remove}</Button>
    </form>
  {/if}
  <h2 class="text-lg font-medium">{a.passkeys}</h2>
  {#if !loaded}
    <p>{t.admin.loading}</p>
  {:else if keys.length === 0}
    <p>{a.noPasskeys}</p>
  {:else}
    <ul class="flex max-w-xl flex-col gap-2">
      {#each keys as k (k.credentialId)}
        <li class="flex items-center justify-between gap-3 rounded-md border p-3 text-sm">
          <span>{k.label}{k.unlocksKeys ? ` · ${a.unlocksKeys}` : ''}</span>
          <Button
            type="button"
            variant="outline"
            disabled={busy || keys.length < 2}
            onclick={() => void remove(k)}>{a.remove}</Button
          >
        </li>
      {/each}
    </ul>
  {/if}

  <Button
    type="button"
    variant="outline"
    onclick={() => {
      showPassword = !showPassword;
    }}>{a.setPassword}</Button
  >
  {#if showPassword}
    <form onsubmit={(e) => void savePassword(e)} class="flex max-w-xl flex-col gap-3">
      <Row id="own-password" label={a.password}>
        <Input
          id="own-password"
          type="password"
          bind:value={ownPassword}
          required
          minlength={12}
          maxlength={256}
          autocomplete="new-password"
        />
      </Row>
      <Button type="submit" disabled={busy}>{a.savePassword}</Button>
    </form>
  {/if}

  {#if session.me?.systemAdministrator}
    <h2 class="text-lg font-medium">{a.create}</h2>
    <form onsubmit={(e) => void create(e)} class="flex max-w-xl flex-col gap-3">
      <Row id="new-username" label={a.username}>
        <Input
          id="new-username"
          bind:value={username}
          required
          autocomplete="off"
          spellcheck={false}
        />
      </Row>
      {#if secondFactorRequired}
        <Row id="new-password" label={a.password}>
          <Input
            id="new-password"
            type="password"
            bind:value={password}
            required
            minlength={12}
            autocomplete="new-password"
          />
        </Row>
      {/if}
      <div><Button type="submit" disabled={busy}>{a.createBtn}</Button></div>
    </form>
    {#if link}
      <div role="group" class="max-w-prose rounded-md border p-3">
        <p class="text-sm font-medium">{a.link}</p>
        <p class="my-2 font-mono text-sm break-all select-all" data-testid="setup-link">{link}</p>
      </div>
    {/if}
  {/if}
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</section>
