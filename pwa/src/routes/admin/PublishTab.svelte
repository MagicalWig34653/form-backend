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
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import NavIcon from '$lib/components/shell/NavIcon.svelte';

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
  const checks = $derived([
    { label: t.formWork.fieldsCheck, target: 'fields' },
    { label: t.formWork.mailCheck, target: 'mail' },
    { label: t.formWork.integrationCheck, target: 'keys' },
  ]);
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

<Panel title={t.formWork.publish} description={t.admin.publish.intro}>
  <p class="text-muted-foreground max-w-prose text-[length:var(--fs-small)]">
    {t.formWork.versionHint}
  </p>
</Panel>
{#if editor.draft}
  <div class="grid min-w-0 gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <Panel title={t.formWork.checks} description={t.formWork.checkHint}>
      <ul class="divide-border-subtle -my-1 divide-y">
        {#each checks as check (check.target)}
          <li>
            <a
              class="hover:bg-surface-sunken -mx-2 flex min-h-11 items-center gap-3 rounded-md px-2"
              href={router.path.replace(/publish$/, check.target)}
            >
              <span
                aria-hidden="true"
                class="bg-info-soft text-info flex size-6 shrink-0 items-center justify-center rounded-full"
                ><NavIcon name="info" size={13} /></span
              >
              <span class="min-w-0 flex-1 underline-offset-4">{check.label}</span>
              <span aria-hidden="true" class="text-muted-foreground"
                ><NavIcon name="chevron" size={14} /></span
              >
            </a>
          </li>
        {/each}
      </ul>
    </Panel>
    <Panel title={t.formUi.publishAction}>
      <div class="flex max-w-md flex-col gap-4">
        {#if canBump}<div class="flex flex-col gap-1.5">
            <div>
              <Button
                type="button"
                variant="outline"
                disabled={editor.saving || busy}
                onclick={() => void bump()}>{t.admin.publish.bump}</Button
              >
            </div>
            <p class="text-muted-foreground text-[length:var(--fs-small)]">
              {t.admin.publish.bumpHint}
            </p>
          </div>
        {/if}
        <label class="flex min-h-11 items-start gap-3 text-sm">
          <input
            type="checkbox"
            bind:checked={confirmed}
            disabled={busy || conflict}
            class="mt-0.5 size-6 shrink-0 accent-[var(--ui-accent)] disabled:opacity-50"
          />
          <span class="pt-0.5">{t.formWork.review}</span>
        </label>
        <Notice
          message={message || (editor.error ? describeError(editor.error) : ok)}
          kind={message || editor.error ? 'error' : 'ok'}
        />
        {#if conflict}
          <Banner tone="danger">
            {t.formWork.conflict}
            {#snippet action()}
              <Button
                variant="outline"
                onclick={async () => {
                  await editor.load();
                  conflict = false;
                  confirmed = false;
                  keyFor = '';
                }}>{t.formWork.reload}</Button
              >
            {/snippet}
          </Banner>
        {/if}
        {#if busy}<p role="status" aria-busy="true" class="text-muted-foreground text-sm">
            {slow ? t.formWork.slow : t.formWork.publishing}
          </p>{/if}
        {#if needLogin}
          <Banner tone="danger">
            {t.admin.publish.reauth}
            {#snippet action()}
              <Button type="button" onclick={() => void reauthenticate(router.path)}
                >{t.admin.publish.reauthButton}</Button
              >
            {/snippet}
          </Banner>
        {:else}
          <div>
            <Button
              type="button"
              disabled={!confirmed || busy || editor.saving || conflict}
              aria-describedby={!confirmed && !busy && !conflict ? 'publish-reason' : undefined}
              onclick={() => void publish()}>{t.admin.publish.action}</Button
            >
            {#if !confirmed && !busy && !conflict}<p
                id="publish-reason"
                class="text-muted-foreground mt-2 text-[length:var(--fs-small)]"
              >
                {t.formUi.publishDisabledReason}
              </p>{/if}
          </div>
        {/if}
      </div>
    </Panel>
  </div>
{:else}
  <Panel>
    <p>{t.formWork.noDraft}</p>
    {#if canBump}<div class="mt-3">
        <Button disabled={editor.saving} onclick={() => void editor.createDraft()}
          >{t.admin.form.createDraft}</Button
        >
      </div>{/if}
  </Panel>
{/if}
