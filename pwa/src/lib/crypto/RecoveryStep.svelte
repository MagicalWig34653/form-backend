<script lang="ts">
  import { adminApi } from '$lib/api';
  import { onMount } from 'svelte';
  import { keyring } from './keyring.svelte';
  import { accessAutomation } from './automation.svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Label } from '$lib/components/ui/label';
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

<section class="border-border flex flex-col gap-4 rounded-lg border p-4" aria-label={c.title}>
  <h2 class="text-base font-semibold">{c.title}</h2>
  {#if keyring.recoveryCode}
    <p class="text-sm">{c.save}</p>
    <p class="bg-amber-500/10 border-amber-500/50 rounded-md border px-3 py-2 text-sm">
      {c.warning}
    </p>
    <p
      class="bg-muted/60 rounded-md px-3 py-3 font-mono text-sm break-all select-all"
      data-testid="account-recovery-code"
    >
      {keyring.recoveryCode}
    </p>
    <div class="flex flex-wrap gap-2">
      <Button type="button" variant="outline" onclick={download}>{c.download}</Button>
      <Button
        type="button"
        variant="outline"
        onclick={async () => {
          try {
            await navigator.clipboard.writeText(keyring.recoveryCode);
          } catch {
            message = c.failed;
          }
        }}>{c.copy}</Button
      >
    </div>
    <form
      class="flex flex-col gap-3"
      onsubmit={(e) => {
        e.preventDefault();
        void perform('confirm');
      }}
    >
      <div class="flex flex-col gap-1.5">
        <Label for="account-recovery-confirm">{c.confirmLabel}</Label>
        <Input
          id="account-recovery-confirm"
          type="password"
          bind:value={input}
          autocomplete="off"
          required
        />
      </div>
      <Button type="submit" disabled={busy}>{c.confirm}</Button>
    </form>
  {:else if !ready}
    <p class="text-sm">{c.save}</p>
    {#if existing && !keyring.unlocked}
      <Button
        type="button"
        disabled={busy}
        onclick={async () => {
          busy = true;
          try {
            const result = await keyring.unlock();
            if (result) message = c.failed;
          } finally {
            busy = false;
          }
        }}>{c.other}</Button
      >
    {:else}
      <Button type="button" disabled={busy} onclick={() => void perform('prepare')}
        >{c.prepare}</Button
      >
    {/if}
  {:else if !keyring.unlocked || security}
    <p class="text-sm">{c.prompt}</p>
    <form
      class="flex flex-col gap-3"
      onsubmit={(e) => {
        e.preventDefault();
        void perform(keyring.unlocked ? 'check' : 'open');
      }}
    >
      <div class="flex flex-col gap-1.5">
        <Label for="account-recovery-input">{c.code}</Label>
        <Input
          id="account-recovery-input"
          type="password"
          bind:value={input}
          autocomplete="off"
          required
        />
      </div>
      <Button type="submit" disabled={busy}>{keyring.unlocked ? c.check : c.open}</Button>
    </form>
    {#if keyring.unlocked}
      <Button
        type="button"
        variant="outline"
        disabled={busy}
        onclick={() => void perform('prepare')}>{c.renew}</Button
      >
    {/if}
  {:else}
    <p role="status" class="text-emerald-700 dark:text-emerald-400 text-sm font-medium">
      {c.saved}
    </p>
    <Button type="button" onclick={oncomplete}>{c.continue}</Button>
  {/if}
  {#if message}<p role="status" class="text-red-700 dark:text-destructive text-sm">
      {message}
    </p>{/if}
</section>
