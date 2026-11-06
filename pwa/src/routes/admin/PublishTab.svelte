<script lang="ts">
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { bumpVersions } from '$lib/draft/doc';
  import { router } from '$lib/router.svelte';
  import { describeError, needsFreshLogin } from '$lib/admin/describe';
  import { handleSessionError, reauthenticate } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import Notice from '$lib/components/admin/Notice.svelte';

  let {
    editor,
    tenant,
    form,
    canBump = false,
  }: { editor: Editor; tenant: string; form: string; canBump?: boolean } = $props();

  let confirmed = $state(false);
  let busy = $state(false);
  let message = $state('');
  let ok = $state('');
  let needLogin = $state(false);
  let conflict = $state(false);
  // One key per attempt of the same draft state: a retry after a lost answer must not publish twice.
  let key = '';
  let keyFor = '';
  let confirmationId = '';
  let slow = $state(false);
  let reviewed = $state('');
  const stamp = $derived(
    editor.draft ? `${editor.draft.id}:${editor.draft.revision}:${editor.draft.hash}` : '',
  );
  $effect(() => {
    if (stamp !== reviewed) {
      confirmed = false;
      reviewed = stamp;
    }
  });
  $effect(() => {
    if (busy) {
      const timer = setTimeout(() => (slow = true), 5000);
      return () => clearTimeout(timer);
    }
    slow = false;
  });

  async function bump(): Promise<void> {
    ok = '';
    const err = await editor.apply(bumpVersions);
    if (!err) {
      ok = t.admin.publish.bumped;
      conflict = false;
    }
  }

  async function publish(): Promise<void> {
    const d = editor.draft;
    if (!d || !confirmed || busy) return;
    busy = true;
    message = ok = '';
    needLogin = conflict = false;
    try {
      const candidate = `${d.id}:${d.revision}:${d.hash}`;
      if (keyFor !== candidate) {
        confirmationId = '';
        keyFor = candidate;
        key = crypto.randomUUID();
      }
      if (!confirmationId) {
        const c = await adminApi.confirmPublication(tenant, form, d.id, d.revision, d.hash);
        if (!c.ok) return fail(c.error);
        confirmationId = c.data.confirmationId;
      }
      const r = await adminApi.publishRelease(
        tenant,
        form,
        d.id,
        d.revision,
        d.hash,
        confirmationId,
        key,
      );
      if (!r.ok) return fail(r.error);
      ok = t.admin.publish.done.replace('{version}', r.data.version);
      confirmed = false;
      await editor.load();
    } finally {
      busy = false;
    }
  }

  function fail(e: Parameters<typeof describeError>[0]): void {
    if (needsFreshLogin(e)) {
      needLogin = true;
      return;
    }
    if (handleSessionError(e)) return;
    if (e.status === 409) {
      conflict = true;
      confirmed = false;
    }
    message = describeError(e);
  }
</script>

<h2 class="text-lg font-medium">{t.formWork.publish}</h2>
<p class="max-w-prose text-sm">{t.admin.publish.intro}</p>

<p class="text-muted-foreground max-w-prose text-sm">{t.formWork.versionHint}</p>
{#if editor.draft}
  <section class="bg-muted/30 border-border rounded-lg border p-4">
    <h3 class="mb-3 font-medium">{t.formWork.checks}</h3>
    <ul class="space-y-2 text-sm">
      <li>
        <a class="underline" href={router.path.replace(/publish$/, 'fields')}
          >{t.formWork.fieldsCheck}</a
        >
      </li>
      <li>
        <a class="underline" href={router.path.replace(/publish$/, 'mail')}
          >{t.formWork.mailCheck}</a
        >
      </li>
      <li>
        <a class="underline" href={router.path.replace(/publish$/, 'keys')}
          >{t.formWork.integrationCheck}</a
        >
      </li>
    </ul>
    <p class="text-muted-foreground mt-3 text-sm">{t.formWork.checkHint}</p>
  </section>
  <div class="flex max-w-md flex-col gap-3">
    {#if canBump}<div class="flex flex-col gap-1">
        <div>
          <Button
            type="button"
            variant="outline"
            disabled={editor.saving || busy}
            onclick={() => void bump()}>{t.admin.publish.bump}</Button
          >
        </div>
        <p class="text-muted-foreground text-xs">{t.admin.publish.bumpHint}</p>
      </div>
    {/if}
    <label class="flex items-start gap-2 text-sm">
      <input
        type="checkbox"
        bind:checked={confirmed}
        disabled={busy || conflict}
        class="mt-0.5 size-4"
      />
      {t.formWork.review}
    </label>
    <Notice
      message={message || (editor.error ? describeError(editor.error) : ok)}
      kind={message || editor.error ? 'error' : 'ok'}
    />
    {#if conflict}<p role="alert" class="text-sm">{t.formWork.conflict}</p>
      <div>
        <Button
          variant="outline"
          onclick={async () => {
            await editor.load();
            conflict = false;
            confirmed = false;
            keyFor = '';
          }}>{t.formWork.reload}</Button
        >
      </div>{/if}
    {#if busy}<p role="status" aria-busy="true">
        {slow ? t.formWork.slow : t.formWork.publishing}
      </p>{/if}
    {#if needLogin}
      <p role="alert" class="text-sm">{t.admin.publish.reauth}</p>
      <div>
        <Button type="button" onclick={() => void reauthenticate(router.path)}
          >{t.admin.publish.reauthButton}</Button
        >
      </div>
    {:else}
      <div>
        <Button
          type="button"
          disabled={!confirmed || busy || editor.saving || conflict}
          onclick={() => void publish()}>{t.admin.publish.action}</Button
        >
      </div>
    {/if}
  </div>
{:else}
  <p>{t.formWork.noDraft}</p>
  {#if canBump}<div>
      <Button disabled={editor.saving} onclick={() => void editor.createDraft()}
        >{t.admin.form.createDraft}</Button
      >
    </div>{/if}
{/if}
