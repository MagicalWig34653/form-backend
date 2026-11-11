<script lang="ts">
  import { confirmAction } from '$lib/confirm.svelte';
  import RecoveryStep from '$lib/crypto/RecoveryStep.svelte';
  import AccessStatus from './AccessStatus.svelte';
  import KeyringPanel from './KeyringPanel.svelte';
  import LegacyKeyAdoption from './LegacyKeyAdoption.svelte';
  import RotationPanel from './RotationPanel.svelte';
  import { onMount, tick } from 'svelte';
  import { createCredential } from '$lib/api/webauthn';
  import { formatDay } from '$lib/format';
  import { t } from '$lib/i18n';
  import { adminApi, authApi, http } from '$lib/api';
  import type { PasskeyInfo } from '$lib/api/admin';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PageHeader from '$lib/components/admin/PageHeader.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import Skeleton from '$lib/components/admin/Skeleton.svelte';

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
  let advancedOpen = $state(false);
  let showPassword = $state(false);
  let ownPassword = $state('');

  function openAdvanced(): void {
    advancedOpen = true;
    void tick().then(() => {
      const summary = document.getElementById('account-advanced');
      summary?.scrollIntoView({ block: 'center' });
      summary?.focus();
    });
  }

  let adding = $state(false);
  async function addPasskey(): Promise<void> {
    if (busy || adding) return;
    adding = true;
    message = ok = '';
    try {
      const options = await authApi.addPasskeyOptions();
      if (!options.ok) {
        if (needsFreshLogin(options.error)) return void (await reauthenticate(router.path));
        if (!handleSessionError(options.error)) message = a.addFailed;
        return;
      }
      const created = await createCredential(options.data);
      if (!created.ok) {
        message =
          created.reason === 'cancelled'
            ? a.addCancelled
            : created.reason === 'duplicate'
              ? a.addDuplicate
              : created.reason === 'unsupported'
                ? a.addUnsupported
                : a.addFailed;
        return;
      }
      const label = a.addDefaultLabel.replace('{date}', formatDay(new Date().toISOString()));
      const verified = await authApi.addPasskeyVerify({ ...created.body, label });
      if (!verified.ok) {
        if (needsFreshLogin(verified.error)) return void (await reauthenticate(router.path));
        if (!handleSessionError(verified.error)) message = a.addFailed;
        return;
      }
      ok = a.added;
      await load();
    } finally {
      adding = false;
    }
  }

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
    if (
      k.unlocksKeys &&
      !(await confirmAction({
        title: t.confirm.removePasskeyTitle,
        description: a.removeWarn,
        confirmLabel: t.confirm.removePasskey,
        destructive: true,
      }))
    )
      return;
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

  onMount(() => {
    void load();
    // Link target of the migration page and the entries notice (ADR 0037): open the legacy key adoption.
    if (new URLSearchParams(router.search).get('legacy') === '1') {
      advancedOpen = true;
      void tick().then(() => {
        const first = document.querySelector<HTMLElement>('[id^="legacy-title-"]');
        first?.scrollIntoView({ block: 'center' });
      });
    }
  });
</script>

<div class="flex w-full min-w-0 flex-col gap-6">
  <PageHeader title={a.title} description={a.intro}>
    {#snippet badges()}
      {#if session.me?.systemAdministrator}<StatusChip
          tone="idle"
          label={t.admin.systemAdministrator}
        />{/if}
    {/snippet}
  </PageHeader>
  <Panel title={t.access.security}>
    <div class="flex flex-col gap-4">
      <AccessStatus showLocked onadvanced={openAdvanced} />
      <RecoveryStep security />
      <details class="border-t pt-3" bind:open={advancedOpen}>
        <summary id="account-advanced" class="min-h-6 cursor-pointer text-sm font-medium"
          >{t.access.advanced}</summary
        >
        <div class="mt-3 flex flex-col gap-4">
          {#each session.tenants as tenant (tenant.id)}
            <h3 class="font-medium">{tenant.name}</h3>
            <KeyringPanel
              tenant={tenant.id}
              keyId={customerKids[tenant.id] ?? null}
              onchange={() => void load()}
            />
            <LegacyKeyAdoption tenant={tenant.id} onchange={() => void load()} />
            <RotationPanel tenant={tenant.id} onchange={() => {}} />
          {/each}
        </div>
      </details>
    </div>
  </Panel>
  <Panel title={c.totp} description={c.totpHint} id="totp">
    <div class="flex flex-col gap-4">
      <p>
        <StatusChip
          tone={totpEnabled ? 'ok' : 'idle'}
          label={totpEnabled ? c.enabled : c.disabled}
        />
      </p>
      {#if !totpEnabled}
        <div>
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onclick={() => void changeTotp('POST')}>{c.setup}</Button
          >
        </div>
        {#if totpSecret}
          <p class="max-w-prose text-sm">{c.setupHint}</p>
          <p class="bg-muted/60 rounded-md px-3 py-2 font-mono break-all select-all">
            {totpSecret}
          </p>
          <form
            onsubmit={(e) => {
              e.preventDefault();
              void changeTotp('PUT');
            }}
            class="flex max-w-[560px] flex-col gap-3"
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
            <div><Button type="submit" disabled={busy}>{c.confirm}</Button></div>
          </form>
        {/if}
      {:else}
        <form
          onsubmit={(e) => {
            e.preventDefault();
            void changeTotp('DELETE');
          }}
          class="flex max-w-[560px] flex-col gap-3"
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
          <div><Button type="submit" variant="outline" disabled={busy}>{c.remove}</Button></div>
        </form>
      {/if}
    </div>
  </Panel>
  <Panel title={a.passkeys}>
    {#snippet actions()}
      <Button
        type="button"
        variant="outline"
        disabled={busy || adding}
        onclick={() => void addPasskey()}>{a.addPasskey}</Button
      >
    {/snippet}
    {#if !loaded}
      <div aria-busy="true" class="flex flex-col gap-2">
        <span class="sr-only" role="status">{t.admin.loading}</span>
        <Skeleton class="h-12" /><Skeleton class="h-12" />
      </div>
    {:else if keys.length === 0}
      <p class="text-muted-foreground text-sm">{a.noPasskeys}</p>
    {:else}
      <ul class="flex flex-col gap-2">
        {#each keys as k (k.credentialId)}
          <li
            class="border-border flex flex-wrap items-center justify-between gap-3 border-b py-3 text-sm last:border-b-0"
          >
            <span class="min-w-0 break-words"
              >{a.passkeyLine
                .replace('{label}', k.label)
                .replace('{date}', formatDay(k.createdAt))}{k.unlocksKeys
                ? ` · ${a.unlocksLong}`
                : ''}</span
            >
            {#if keys.length < 2}
              <span class="text-muted-foreground inline-flex items-center gap-1.5 text-sm"
                ><NavIcon name="locked" size={14} />{a.lastOneLabel}</span
              >
            {:else}
              <Button type="button" variant="outline" disabled={busy} onclick={() => void remove(k)}
                >{a.remove}</Button
              >
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </Panel>
  <Panel title={a.passwordTitle} description={a.passwordIntro}>
    {#snippet actions()}
      <Button
        type="button"
        variant="outline"
        aria-expanded={showPassword}
        onclick={() => {
          showPassword = !showPassword;
        }}>{a.setPassword}</Button
      >
    {/snippet}
    <div class="flex flex-col gap-4">
      {#if showPassword}
        <form onsubmit={(e) => void savePassword(e)} class="flex max-w-[560px] flex-col gap-3">
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
          <div><Button type="submit" disabled={busy}>{a.savePassword}</Button></div>
        </form>
      {/if}
    </div>
  </Panel>
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
</div>
