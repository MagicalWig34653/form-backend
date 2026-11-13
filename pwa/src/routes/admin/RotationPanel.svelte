<script lang="ts">
  import { onMount } from 'svelte';
  import { adminApi } from '$lib/api';
  import type { KeyCandidate, RotationState } from '$lib/api/admin';
  import { t } from '$lib/i18n';
  import { keyring } from '$lib/crypto/keyring.svelte';
  import { rewrapPackage } from '$lib/crypto/rewrap';
  import { fromBase64Url } from '$lib/crypto/packageV2';
  import { fingerprint } from '$lib/crypto/keys';
  import { session } from '$lib/session.svelte';
  import { describeError } from '$lib/admin/describe';
  import { Button } from '$lib/components/ui/button';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import Notice from '$lib/components/admin/Notice.svelte';

  let { tenant, onchange }: { tenant: string; onchange: () => void } = $props();
  const r = t.rotation;
  let rotation = $state<RotationState | null>(null);
  let candidates = $state<KeyCandidate[]>([]);
  let fingerprints = $state<Record<string, string>>({});
  let selected = $state<Record<string, boolean>>({});
  let busy = $state(false);
  let message = $state('');
  let completed = $state(0);
  let result = $state('');
  let mounted = true;
  let cancelRewrap: (() => void) | undefined;

  async function refresh(): Promise<void> {
    const response = await adminApi.rotation(tenant);
    if (response.ok) rotation = response.data;
    else if (response.error.status !== 404) message = describeError(response.error);
    if (!keyring.unlocked) return;
    const c = await adminApi.keyCandidates(tenant);
    if (c.ok) {
      candidates = c.data.items.filter((c) => c.hasAccess && c.accountId !== session.me?.id);
      for (const item of candidates)
        fingerprints[item.accountId] = await fingerprint(fromBase64Url(item.publicKey));
    }
  }

  async function run(action: () => Promise<void>): Promise<void> {
    if (busy) return;
    busy = true;
    message = result = '';
    try {
      await action();
    } catch (error) {
      message = error instanceof Error ? error.message : r.failed;
    } finally {
      busy = false;
    }
  }

  async function begin(): Promise<void> {
    if (!rotation?.active || !session.me) return;
    const issue = await keyring.beginRotation(
      tenant,
      session.me.id,
      rotation.active.kid,
      candidates.filter((c) => selected[c.accountId]),
    );
    if (issue) throw new Error(r.failed);
    completed = 0;
    await refresh();
    onchange();
  }

  async function rewrap(): Promise<void> {
    if (!rotation?.retiring || !rotation.active) return;
    const oldKid = rotation.retiring.kid;
    const newKid = rotation.active.kid;
    const operation = keyring.operation();
    const old = keyring.dataKey(oldKid);
    const next = keyring.dataKey(newKid);
    if (!old || !next) {
      operation.dispose();
      throw new Error(r.noAccess);
    }
    const oldCopy = operation.copy(old);
    const nextCopy = operation.copy(next);
    cancelRewrap = () => operation.dispose();
    try {
      let after = '';
      do {
        const page = await adminApi.rotationObjects(tenant, oldKid, after);
        operation.check();
        if (!page.ok) throw new Error(describeError(page.error));
        for (const object of page.data.items) {
          const wire = await rewrapPackage(
            object.package,
            oldCopy,
            object.held || object.wrapKind === 'sym'
              ? { wrap: 'sym', secret: nextCopy }
              : {
                  wrap: 'hpke',
                  publicKey: fromBase64Url(rotation.active.publicKey),
                  secret: nextCopy,
                },
            undefined,
            operation,
          );
          operation.check();
          if (!mounted) throw new Error(r.noAccess);
          const saved = await adminApi.rewrapObject(tenant, object.id, {
            expectedRevision: object.revision,
            expectedSha256: object.ciphertext_sha256,
            package: wire,
          });
          operation.check();
          if (!saved.ok) throw new Error(describeError(saved.error));
          completed++;
        }
        after = page.data.next ?? '';
      } while (after);
      result = r.next;
    } finally {
      operation.dispose();
      cancelRewrap = undefined;
    }
  }

  async function finish(): Promise<void> {
    if (!rotation?.retiring || !rotation.active) return;
    const response = await adminApi.finishRotation(tenant, rotation.retiring.kid);
    if (!response.ok) throw new Error(describeError(response.error));
    // Remove retired private material from memory and reopen remaining accesses explicitly.
    keyring.lock();
    result = r.finished;
    await refresh();
    onchange();
  }

  async function revoke(accountId: string): Promise<void> {
    const response = await adminApi.revokeKeyAccess(tenant, accountId);
    if (!response.ok) throw new Error(describeError(response.error));
    result = r.revoked;
    await refresh();
  }

  onMount(() => {
    void refresh();
    return () => {
      mounted = false;
      cancelRewrap?.();
    };
  });
</script>

<h2 class="text-lg font-medium">{r.title}</h2>
<p class="text-muted-foreground max-w-prose text-sm">{r.intro}</p>
{#if rotation?.active}
  <p class="text-sm">{r.active}: <code>{rotation.active.kid}</code></p>
  {#if rotation.retiring}
    <p class="text-sm">{r.retiring}: <code>{rotation.retiring.kid}</code></p>
  {:else if keyring.unlocked && candidates.length}
    <fieldset class="max-w-xl space-y-2">
      <legend class="text-sm font-medium">{r.recipients}</legend>
      {#each candidates as candidate (candidate.accountId)}
        <div class="flex flex-wrap items-center gap-2 text-sm">
          <label class="flex items-center gap-2"
            ><Checkbox bind:checked={selected[candidate.accountId]} disabled={busy} />
            {candidate.username} · {fingerprints[candidate.accountId] ?? ''}</label
          >
          <Button
            type="button"
            variant="outline"
            disabled={busy}
            onclick={() => void run(() => revoke(candidate.accountId))}>{r.revoke}</Button
          >
        </div>
      {/each}
    </fieldset>
  {/if}
  <div class="flex flex-wrap gap-2">
    {#if rotation.retiring}
      <Button
        type="button"
        disabled={busy || !keyring.unlocked || !!keyring.pendingCode}
        onclick={() => void run(rewrap)}>{r.rewrap}</Button
      >
      <Button
        type="button"
        variant="outline"
        disabled={busy || !keyring.unlocked || !!keyring.pendingCode}
        onclick={() => void run(finish)}>{r.finish}</Button
      >
    {:else}
      <Button
        type="button"
        disabled={busy || !keyring.unlocked || !!keyring.pendingCode}
        onclick={() => void run(begin)}>{r.begin}</Button
      >
    {/if}
    <Button type="button" variant="outline" disabled={busy} onclick={() => void run(refresh)}
      >{r.refresh}</Button
    >
  </div>
  {#if keyring.pendingCode}<p class="text-sm">{r.codePending}</p>{/if}
  <p role="status" aria-live="polite" class="text-sm">
    {r.progress.replace('{n}', String(completed))}
  </p>
{/if}
<Notice message={message || result} kind={message ? 'error' : 'ok'} />
