<script lang="ts">
  /** The "locked" notice is shown only where it matters (account page); elsewhere the top bar chip says it. */
  let { showLocked = false }: { showLocked?: boolean } = $props();
  import { t } from '$lib/i18n';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { accessAutomation } from '$lib/crypto/automation.svelte';
  import { normalizeRecovery } from '$lib/crypto/keys';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Banner from '$lib/components/admin/Banner.svelte';
  import Row from '$lib/components/admin/Row.svelte';
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
  <section
    role="group"
    aria-label={t.access.title}
    class="bg-amber-500/10 ring-1 ring-amber-500/50 rounded-xl space-y-3 p-5"
  >
    <h2 class="text-xl leading-snug font-semibold tracking-tight">{t.access.title}</h2>
    <p>{t.access.warning}</p>
    <p
      class="bg-muted/60 rounded-md px-3 py-2 font-mono break-all select-all"
      data-testid="recovery-code"
    >
      {keyring.pendingCode}
    </p>
    <Row id="access-code-confirm" label={t.access.confirmLabel}>
      <Input
        id="access-code-confirm"
        type="password"
        bind:value={confirmation}
        autocomplete="off"
      />
    </Row>
    <Button type="button" onclick={confirm}>{t.access.confirm}</Button>
    {#if wrong}<p role="alert" class="text-red-700 dark:text-destructive text-sm">
        {t.access.wrong}
      </p>{/if}
  </section>
{:else if showLocked && !keyring.unlocked}
  <Banner tone="warn">{t.access.locked}</Banner>
{/if}
{#if accessAutomation.busy}
  <Banner tone="warn">{t.access.updating}</Banner>
{/if}
{#if accessAutomation.message}<Banner tone="info">{accessAutomation.message}</Banner>{/if}
