<script lang="ts">
  import { t } from '$lib/i18n';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { normalizeRecovery } from '$lib/crypto/keys';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  let confirmation = $state('');
  let wrong = $state(false);
  function confirm(): void {
    wrong = normalizeRecovery(confirmation) !== normalizeRecovery(keyring.pendingCode);
    confirmation = '';
    if (!wrong) {
      keyring.pendingCode = '';
      void accessAutomation.run();
    }
  }
</script>

{#if keyring.pendingCode}
  <section role="group" aria-label={t.access.title} class="space-y-3 rounded-md border p-3">
    <h2 class="font-medium">{t.access.title}</h2>
    <p>{t.access.warning}</p>
    <p class="font-mono break-all select-all" data-testid="recovery-code">{keyring.pendingCode}</p>
    <label for="access-code-confirm">{t.access.confirmLabel}</label>
    <Input id="access-code-confirm" type="password" bind:value={confirmation} autocomplete="off" />
    <Button type="button" onclick={confirm}>{t.access.confirm}</Button>
    {#if wrong}<p role="alert">{t.access.wrong}</p>{/if}
  </section>
{:else if !keyring.unlocked}
  <p role="status" class="text-muted-foreground text-sm">{t.access.locked}</p>
{/if}
{#if accessAutomation.busy}
  <p role="status" class="text-muted-foreground text-sm">{t.access.updating}</p>
{/if}
{#if accessAutomation.message}<p role="status" class="text-sm">{accessAutomation.message}</p>{/if}
