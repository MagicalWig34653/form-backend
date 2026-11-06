<script lang="ts">
  import { adminApi } from '$lib/api';
  import { onMount } from 'svelte';
  import { keyring } from './keyring.svelte';
  import { accessAutomation } from './automation.svelte';
  import { t } from '$lib/i18n';
  let { oncomplete = () => {}, security = false }: { oncomplete?: () => void; security?: boolean } =
    $props();
  const c = t.recovery;
  let input = $state('');
  let message = $state('');
  let busy = $state(false);
  let ready = $state(false);
  let existing = $state(false);
  onMount(() => {
    void load();
    return keyring.onLock(() => {
      input = '';
      message = '';
    });
  });
  async function load() {
    const b = await adminApi.keyBundle();
    ready = b.ok && !!b.data.recovery;
    if (b.ok) {
      keyring.recoveryRequired = !b.data.recovery;
      existing = !!b.data.accountPublicKey;
    }
  }
  async function perform(action: 'prepare' | 'confirm' | 'open' | 'check') {
    if (busy) return;
    busy = true;
    message = '';
    try {
      const result =
        action === 'prepare'
          ? await keyring.prepareRecovery()
          : action === 'confirm'
            ? await keyring.confirmRecovery(input)
            : await keyring.recoverAccount(input, action === 'check');
      input = '';
      if (result) message = c.failed;
      else if (action === 'check') message = c.valid;
      else if (action !== 'prepare') {
        ready = true;
        void accessAutomation.run();
        oncomplete();
      }
    } catch {
      message = c.failed;
    } finally {
      busy = false;
    }
  }
  function download() {
    const url = URL.createObjectURL(
      new Blob([keyring.recoveryCode + '\n'], { type: 'text/plain' }),
    );
    const a = document.createElement('a');
    a.href = url;
    a.download = 'Wiederherstellungscode.txt';
    a.click();
    URL.revokeObjectURL(url);
  }
</script>

<section class="space-y-3 rounded-md border p-3" aria-label={c.title}>
  <h2>{c.title}</h2>
  {#if keyring.recoveryCode}
    <p>{c.save}</p>
    <p>{c.warning}</p>
    <p class="font-mono select-all" data-testid="account-recovery-code">{keyring.recoveryCode}</p>
    <button onclick={download}>{c.download}</button>
    <button
      onclick={async () => {
        try {
          await navigator.clipboard.writeText(keyring.recoveryCode);
        } catch {
          message = c.failed;
        }
      }}>{c.copy}</button
    >
    <form
      onsubmit={(e) => {
        e.preventDefault();
        void perform('confirm');
      }}
    >
      <label for="account-recovery-confirm">{c.confirmLabel}</label>
      <input
        id="account-recovery-confirm"
        type="password"
        bind:value={input}
        autocomplete="off"
        required
      />
      <button disabled={busy}>{c.confirm}</button>
    </form>
  {:else if !ready}
    <p>{c.save}</p>
    {#if existing && !keyring.unlocked}
      <button
        disabled={busy}
        onclick={async () => {
          busy = true;
          try {
            const result = await keyring.unlock();
            if (result) message = c.failed;
          } finally {
            busy = false;
          }
        }}>{c.other}</button
      >
    {:else}
      <button disabled={busy} onclick={() => void perform('prepare')}>{c.prepare}</button>
    {/if}
  {:else if !keyring.unlocked || security}
    <p>{c.prompt}</p>
    <form
      onsubmit={(e) => {
        e.preventDefault();
        void perform(keyring.unlocked ? 'check' : 'open');
      }}
    >
      <label for="account-recovery-input">{c.code}</label>
      <input
        id="account-recovery-input"
        type="password"
        bind:value={input}
        autocomplete="off"
        required
      />
      <button disabled={busy}>{keyring.unlocked ? c.check : c.open}</button>
    </form>
    {#if keyring.unlocked}<button disabled={busy} onclick={() => void perform('prepare')}
        >{c.renew}</button
      >{/if}
  {:else}
    <p role="status">{c.saved}</p>
    <button onclick={oncomplete}>{c.continue}</button>
  {/if}
  {#if message}<p role="status">{message}</p>{/if}
</section>
