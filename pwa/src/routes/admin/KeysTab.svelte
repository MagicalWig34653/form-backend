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
  import RichText from '$lib/components/admin/RichText.svelte';
  import { scrollHint } from '$lib/scrollHint';

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

  let snippetCopied = $state('');
  async function copySnippet(): Promise<void> {
    try {
      await navigator.clipboard.writeText(t.phpSdk.code);
      snippetCopied = t.phpSdk.copied;
    } catch {
      sdkMessage = t.formWork.copyError;
    }
  }

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

{#snippet step(n: number, title: string)}
  <span
    aria-hidden="true"
    class="bg-muted text-muted-foreground flex size-7 shrink-0 items-center justify-center rounded-full text-sm font-medium"
    >{n}</span
  >
  <h3 class="m-0 text-base font-semibold">{title}</h3>
{/snippet}

<Panel title={t.phpSdk.title} description={t.phpSdk.description}>
  <ol class="m-0 flex list-none flex-col gap-6 p-0">
    <li class="flex flex-col gap-2">
      <div class="flex items-center gap-3">{@render step(1, t.phpSdk.steps[0].title)}</div>
      <p class="text-muted-foreground m-0 text-sm"><RichText text={t.phpSdk.steps[0].text} /></p>
    </li>
    <li class="flex flex-col gap-3">
      <div class="flex items-center gap-3">{@render step(2, t.phpSdk.steps[1].title)}</div>
      <p class="text-muted-foreground m-0 text-sm"><RichText text={t.phpSdk.steps[1].text} /></p>
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
          <Button type="button" variant="outline" onclick={() => void copy()}>{t.admin.copy}</Button
          >
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
    </li>
    <li class="flex flex-col gap-2">
      <div class="flex items-center gap-3">{@render step(3, t.phpSdk.steps[2].title)}</div>
      <p class="text-muted-foreground m-0 text-sm"><RichText text={t.phpSdk.steps[2].text} /></p>
    </li>
    <li class="flex flex-col gap-2">
      <div class="flex items-center gap-3">{@render step(4, t.phpSdk.steps[3].title)}</div>
      <p class="text-muted-foreground m-0 text-sm"><RichText text={t.phpSdk.steps[3].text} /></p>
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span id="php-snippet-label" class="text-sm font-medium">{t.phpSdk.snippetLabel}</span>
        <Button type="button" variant="outline" onclick={() => void copySnippet()}
          >{t.phpSdk.copy}</Button
        >
      </div>
      <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
      <pre
        use:scrollHint
        tabindex="0"
        aria-labelledby="php-snippet-label"
        class="border-border bg-muted/60 focus-visible:ring-ring/50 m-0 max-w-full overflow-x-auto rounded-lg border p-3 font-mono text-xs leading-5 whitespace-pre focus-visible:ring-3 focus-visible:outline-none"><code
          >{t.phpSdk.code}</code
        ></pre>
      <Notice message={snippetCopied} kind="ok" />
      <details class="text-muted-foreground text-sm">
        <summary class="min-h-8 cursor-pointer py-1 font-medium">{t.phpSdk.notes}</summary>
        <ul class="m-0 mt-1 flex list-disc flex-col gap-1 pl-5">
          <li><RichText text={t.phpSdk.urlNote} /></li>
          <li><RichText text={t.phpSdk.clock} /></li>
          <li><RichText text={t.phpSdk.retry} /></li>
          <li><RichText text={t.phpSdk.docs} /></li>
        </ul>
      </details>
    </li>
  </ol>
</Panel>
<Panel title={t.formWork.domains} description={t.formWork.domainsPending} />
