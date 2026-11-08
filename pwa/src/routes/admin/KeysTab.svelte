<script lang="ts">
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { SdkCredentials } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';

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

<Panel title={t.formWork.sdk} description={t.formWork.sdkIntro}>
  <div class="flex flex-col gap-3">
    {#if creds}
      <Banner tone="warn">{t.formWork.once}</Banner>
      <label for="creds-file" class="text-sm font-medium">{t.formWork.file}</label>
      <textarea
        id="creds-file"
        readonly
        rows="12"
        class="border-border bg-muted/60 max-w-2xl rounded-lg border p-3 font-mono text-xs"
        value={file}></textarea>
      <div class="flex flex-wrap gap-2">
        <Button type="button" variant="outline" onclick={() => void copy()}>{t.admin.copy}</Button>
        <Button type="button" variant="outline" onclick={download}>{t.formWork.download}</Button>
        <Button
          type="button"
          variant="ghost"
          onclick={() => {
            creds = null;
            copied = '';
          }}>{t.formWork.forget}</Button
        >
      </div>
      <Notice message={copied} kind="ok" />
    {:else}
      <p class="text-muted-foreground text-sm">{t.formWork.notConfigured}</p>
      {#if !canIssue}<Banner tone="danger">{t.formWork.denied}</Banner>{/if}
      {#if canIssue}<div>
          <Button
            type="button"
            disabled={busy || !canIssue || !editor.detail?.currentReleaseId}
            aria-describedby={!editor.detail?.currentReleaseId ? 'issue-reason' : undefined}
            onclick={() => void createCredentials()}>{t.formWork.issue}</Button
          >
          {#if !editor.detail?.currentReleaseId}<p
              id="issue-reason"
              class="text-muted-foreground mt-2 text-sm"
            >
              {t.formWork.needsRelease}
            </p>{/if}
        </div>{/if}
    {/if}
    <Notice message={sdkMessage} />
    {#if busy}<p role="status" aria-busy="true" class="text-muted-foreground text-sm">
        {slow ? t.formWork.slow : t.admin.loading}
      </p>{/if}
  </div>
</Panel>
<Panel title={t.formWork.domains} description={t.formWork.domainsPending} />
