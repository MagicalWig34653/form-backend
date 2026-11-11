<script lang="ts">
  /** ADR 0037: take over an imported legacy customer key in this browser (private key never leaves the tab). */
  import { t } from '$lib/i18n';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { parseLegacyPrivateKey } from '$lib/crypto/legacyAdoption';
  import { session } from '$lib/session.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';

  let { tenant, onchange }: { tenant: string; onchange?: () => void } = $props();
  const l = t.admin.legacyKey;
  let keyInput = $state('');
  let busy = $state(false);
  let message = $state('');
  let ok = $state('');
  let next = $state(false);
  const fieldId = $derived(`legacy-key-${tenant}`);

  $effect(() => () => {
    keyInput = '';
  });

  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const text = keyInput;
    keyInput = ''; // cleared at once: the key must not linger in the field
    if (busy) return;
    message = ok = '';
    next = false;
    const me = session.me;
    if (!me) return;
    let secret: Uint8Array;
    try {
      secret = parseLegacyPrivateKey(text);
    } catch {
      message = l.format;
      return;
    }
    busy = true;
    try {
      // adoptLegacyKey owns and wipes `secret` on every path
      const result = await keyring.adoptLegacyKey(tenant, me.id, secret);
      if (typeof result === 'string') {
        message =
          result === 'mismatch'
            ? l.mismatch
            : result === 'no-account-key'
              ? l.noAccountKey
              : result === 'locked'
                ? l.lockedHint
                : l.failed;
        return;
      }
      ok = l.done.replace('{kid}', result.kid);
      next = true;
      onchange?.();
    } catch {
      message = l.failed;
    } finally {
      secret.fill(0);
      busy = false;
    }
  }
</script>

<section
  id={`legacy-${tenant}`}
  class="flex max-w-xl flex-col gap-3"
  aria-labelledby={`legacy-title-${tenant}`}
>
  <h3 id={`legacy-title-${tenant}`} class="font-medium">{l.title}</h3>
  <p class="text-muted-foreground max-w-prose text-sm">{l.intro}</p>
  {#if !keyring.unlocked}
    <p class="text-sm">{l.lockedHint}</p>
  {:else}
    <form onsubmit={(e) => void submit(e)} class="flex flex-col gap-3">
      <Row id={fieldId} label={l.key}>
        <Input
          id={fieldId}
          type="password"
          bind:value={keyInput}
          required
          autocomplete="off"
          autocapitalize="off"
          spellcheck={false}
          class="font-mono"
        />
      </Row>
      <div><Button type="submit" variant="outline" disabled={busy}>{l.submit}</Button></div>
    </form>
  {/if}
  <p class="text-muted-foreground max-w-prose text-sm">{l.recoveryHint}</p>
  <Notice message={message || ok} kind={message ? 'error' : 'ok'} />
  {#if next}<p class="max-w-prose text-sm">{l.next}</p>{/if}
</section>
