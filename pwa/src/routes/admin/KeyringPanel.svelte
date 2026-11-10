<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { KeyCandidate } from '$lib/api/admin';
  import { keyring, type KeyringIssue } from '$lib/crypto/keyring.svelte';
  import { fingerprint } from '$lib/crypto/keys';
  import { fromBase64Url } from '$lib/api/webauthn';
  import { session } from '$lib/session.svelte';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import Row from '$lib/components/admin/Row.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import PrfHint from '$lib/crypto/PrfHint.svelte';

  let { tenant, keyId, onchange }: { tenant: string; keyId: string | null; onchange: () => void } =
    $props();
  const k = t.admin.keyring;

  let hasAccountKey = $state<boolean | null>(null);
  let message = $state('');
  let ok = $state('');
  let busy = $state(false);
  let recoverInput = $state('');
  let candidates = $state<KeyCandidate[]>([]);
  let fingerprints = $state<Record<string, string>>({});
  let ownFingerprint = $state('');
  let keyMismatch = $state(false);
  let verified = $state<Record<string, boolean>>({});

  const unlockedKeys = $derived(keyring.kids.length);

  function say(issue: KeyringIssue | null, done = ''): void {
    message = ok = '';
    if (!issue) ok = done;
    else
      message =
        issue === 'unsupported'
          ? keyring.prfMissing
            ? ''
            : k.noPrf
          : issue === 'mismatch'
            ? k.mismatch
            : issue === 'no-account-key'
              ? k.noAccountKey
              : k.failed;
  }

  async function refresh(): Promise<void> {
    const b = await adminApi.keyBundle();
    if (!b.ok) {
      handleSessionError(b.error);
      return;
    }
    hasAccountKey = b.data.accountPublicKey !== null;
    // The own fingerprint is derived from the key unlocked in THIS browser; the server's copy is only compared (review H1).
    ownFingerprint = keyring.localPublicKey
      ? await fingerprint(fromBase64Url(keyring.localPublicKey))
      : '';
    keyMismatch = !!keyring.localPublicKey && keyring.localPublicKey !== b.data.accountPublicKey;
    if (keyring.unlocked && keyId) {
      const c = await adminApi.keyCandidates(tenant);
      candidates = c.ok ? c.data.items : [];
      for (const x of candidates)
        fingerprints[x.accountId] = await fingerprint(fromBase64Url(x.publicKey));
    }
  }

  async function run(f: () => Promise<KeyringIssue | null>, done: string): Promise<void> {
    if (busy) return;
    busy = true;
    try {
      say(await f(), done);
    } catch {
      say('server');
    } finally {
      busy = false;
    }
    await refresh();
    onchange();
  }

  async function create(): Promise<void> {
    if (busy) return;
    busy = true;
    message = ok = '';
    try {
      const r = await keyring.createCustomerKey(tenant);
      if (typeof r === 'string') {
        say(r);
        return;
      }
      ok = k.created.replace('{kid}', r.kid);
    } catch {
      say('server');
      return;
    } finally {
      busy = false;
    }
    onchange();
  }

  async function recover(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const code = recoverInput;
    recoverInput = ''; // cleared at once: the code must not linger in the field, and a later entry must not be wiped
    await run(() => keyring.recover(tenant, code, keyId ?? ''), k.recovered);
  }

  async function repair(): Promise<void> {
    const me = session.me;
    if (!me || !keyId) return;
    await run(() => keyring.repairOwnAccess(tenant, me.id, keyId), k.repaired);
  }

  async function grant(c: KeyCandidate): Promise<void> {
    if (!keyId) return;
    await run(() => keyring.grant(tenant, c, keyId), k.granted);
  }

  onMount(() => void refresh());
</script>

<h2 class="text-lg font-medium">{k.title}</h2>
<p class="text-muted-foreground max-w-prose text-sm">{k.intro}</p>

<p class="text-sm">
  {keyring.unlocked ? k.unlockedKeys.replace('{n}', String(unlockedKeys)) : k.locked}
</p>
{#if keyMismatch}
  <p role="alert" class="text-destructive text-sm">{k.serverKeyMismatch}</p>
{:else if ownFingerprint}
  <p class="text-muted-foreground text-sm">
    {k.yourFingerprint.replace('{fp}', ownFingerprint)}
  </p>
{/if}
<div class="flex flex-wrap gap-2">
  {#if hasAccountKey === false}
    <Button
      type="button"
      disabled={busy}
      onclick={() => void run(() => keyring.setupAccountKey(), k.locked)}>{k.setup}</Button
    >
  {:else if hasAccountKey && !keyring.unlocked}
    <Button type="button" disabled={busy} onclick={() => void run(() => keyring.unlock(), '')}
      >{k.unlock}</Button
    >
  {/if}
  {#if keyring.unlocked}
    <Button type="button" variant="outline" onclick={() => keyring.lock()}>{k.lock}</Button>
    <Button
      type="button"
      variant="outline"
      disabled={busy}
      onclick={() => void run(() => keyring.addPasskey(), '')}>{k.addPasskey}</Button
    >
    {#if !keyId}
      <Button type="button" disabled={busy} onclick={() => void create()}>{k.create}</Button>
    {/if}
  {/if}
</div>

{#if keyId}
  <h3 class="font-medium">{k.recoverTitle}</h3>
  <form onsubmit={(e) => void recover(e)} class="flex max-w-xl flex-col gap-3">
    <Row id="recovery-code" label={k.recoverCode}>
      <Input
        id="recovery-code"
        type="password"
        bind:value={recoverInput}
        required
        autocomplete="off"
        spellcheck={false}
      />
    </Row>
    <div><Button type="submit" variant="outline" disabled={busy}>{k.recover}</Button></div>
  </form>
{/if}

{#if keyring.unlocked && keyId && keyring.kids.includes(keyId)}
  <div>
    <Button type="button" variant="outline" disabled={busy} onclick={() => void repair()}
      >{k.repair}</Button
    >
  </div>
{/if}

{#if keyring.unlocked && keyId}
  <h3 class="font-medium">{k.grantTitle}</h3>
  <p class="text-muted-foreground max-w-prose text-sm">{k.fingerprintHint}</p>
  {#if candidates.filter((c) => !c.hasAccess).length === 0}
    <p class="text-muted-foreground text-sm">{k.grantNone}</p>
  {:else}
    <ul class="flex max-w-xl flex-col gap-3">
      {#each candidates.filter((c) => !c.hasAccess) as c (c.accountId)}
        <li class="flex flex-col gap-1 text-sm">
          <label class="flex items-start gap-2">
            <Checkbox bind:checked={verified[c.accountId]} />
            <span
              >{k.fingerprintConfirm
                .replace('{name}', c.username)
                .replace('{fp}', fingerprints[c.accountId] ?? '')}</span
            >
          </label>
          <div>
            <Button
              type="button"
              variant="outline"
              disabled={busy || !verified[c.accountId]}
              onclick={() => void grant(c)}>{k.grant}</Button
            >
          </div>
        </li>
      {/each}
    </ul>
  {/if}
{/if}
{#if keyring.prfMissing && !keyring.unlocked}<PrfHint />{/if}
<Notice message={message || ok} kind={message ? 'error' : 'ok'} />
