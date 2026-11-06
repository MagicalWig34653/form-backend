<script lang="ts">
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { SdkCredentials } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';

  let {
    editor,
    tenant,
    form,
    canIssue = false,
  }: { editor: Editor; tenant: string; form: string; canIssue?: boolean } = $props();

  let creds = $state<SdkCredentials | null>(null);
  let sdkMessage = $state('');
  let copied = $state('');
  let busy = $state(false);
  let slow = $state(false);
  $effect(() => {
    if (busy) {
      const timer = setTimeout(() => (slow = true), 5000);
      return () => clearTimeout(timer);
    }
    slow = false;
  });

  const file = $derived(creds ? JSON.stringify(creds, null, 2) + '\n' : '');

  async function createCredentials(): Promise<void> {
    if (busy || !canIssue || !editor.detail?.currentReleaseId) return;
    busy = true;
    sdkMessage = copied = '';
    const r = await adminApi.sdkCredentials(tenant, form);
    busy = false;
    if (!r.ok) {
      if (needsFreshLogin(r.error)) {
        sdkMessage = t.admin.keys.needsFresh;
        return;
      }
      if (!handleSessionError(r.error))
        sdkMessage = r.error.status === 409 ? t.formWork.needsRelease : describeError(r.error);
      return;
    }
    creds = r.data;
  }

  async function copy(): Promise<void> {
    try {
      await navigator.clipboard.writeText(file);
      copied = t.admin.copied;
    } catch {
      sdkMessage = t.formWork.copyError;
    }
  }

  function download(): void {
    const url = URL.createObjectURL(new Blob([file], { type: 'application/json' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = 'form-backend-credentials.json';
    a.click();
    URL.revokeObjectURL(url);
  }

  // The secret must not outlive the page view.
  $effect(() => () => {
    creds = null;
  });
</script>

<h2 class="text-lg font-medium">{t.formWork.sdk}</h2>
<p class="text-muted-foreground max-w-prose text-sm">{t.formWork.sdkIntro}</p>
{#if creds}
  <p role="alert" class="max-w-prose text-sm font-medium">{t.formWork.once}</p>
  <label for="creds-file" class="text-sm font-medium">{t.formWork.file}</label>
  <textarea
    id="creds-file"
    readonly
    rows="12"
    class="border-border bg-background max-w-xl rounded-md border p-3 font-mono text-xs"
    value={file}></textarea>
  <div class="flex gap-2">
    <Button type="button" variant="outline" onclick={() => void copy()}>{t.admin.copy}</Button>
    <Button type="button" variant="outline" onclick={download}>{t.formWork.download}</Button>
  </div>
  <Button
    type="button"
    variant="ghost"
    onclick={() => {
      creds = null;
      copied = '';
    }}>{t.formWork.forget}</Button
  >
  <Notice message={copied} kind="ok" />
{:else}
  <p>{t.formWork.notConfigured}</p>
  {#if !canIssue}<p role="alert">{t.formWork.denied}</p>
  {:else if !editor.detail?.currentReleaseId}<p>{t.formWork.needsRelease}</p>{/if}
  {#if canIssue}<div>
      <Button
        type="button"
        disabled={busy || !canIssue || !editor.detail?.currentReleaseId}
        onclick={() => void createCredentials()}>{t.formWork.issue}</Button
      >
    </div>{/if}
{/if}
<Notice message={sdkMessage} />

{#if busy}<p role="status" aria-busy="true">{slow ? t.formWork.slow : t.admin.loading}</p>{/if}
<h2 class="mt-4 text-lg font-medium">{t.formWork.domains}</h2>
<p class="text-muted-foreground max-w-prose text-sm">{t.formWork.domainsPending}</p>
