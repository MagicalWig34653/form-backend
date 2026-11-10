<script lang="ts">
  import { Checkbox } from '$lib/components/ui/checkbox';
  import { fieldList } from '$lib/draft/doc';
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
  // done: true = fine, false = open, null = cannot be derived from the draft (manual check).
  const checks = $derived<{ label: string; target: string; done: boolean | null }[]>([
    {
      label: t.formWork.fieldsCheck,
      target: 'fields',
      done: editor.draft ? fieldList(editor.draft.document).length > 0 : false,
    },
    { label: t.formWork.mailCheck, target: 'mail', done: !!editor.detail?.mailConnectionId },
    { label: t.formWork.integrationCheck, target: 'keys', done: null },
  ]);
  const open = $derived(checks.filter((check) => check.done === false).length);
  const summary = $derived(
    open > 0
      ? open === 1
        ? t.formUi.checksOpenOne
        : t.formUi.checksOpen.replace('{n}', String(open))
      : t.formUi.checksClear,
  );
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
      void reauthenticate(router.path);
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

{#if editor.draft}
  <div class="grid min-w-0 gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
    <Panel title={t.formWork.checks} description={summary}>
      <ul class="divide-border -my-1 divide-y">
        {#each checks as check (check.target)}
          <li>
            <a
              class="hover:bg-muted -mx-2 flex min-h-11 items-center gap-3 rounded-md px-2"
              href={router.path.replace(/publish$/, check.target)}
            >
              <span
                aria-hidden="true"
                class={`flex size-6 shrink-0 items-center justify-center rounded-full ${check.done ? 'bg-emerald-500/10 text-emerald-700 dark:text-emerald-400' : check.done === false ? 'bg-amber-500/10 text-amber-800 dark:text-amber-400' : 'bg-muted text-muted-foreground'}`}
                ><NavIcon
                  name={check.done ? 'check' : check.done === false ? 'warn' : 'info'}
                  size={13}
                /></span
              >
              <span class="min-w-0 flex-1 underline-offset-4">{check.label}</span>
              <span class="text-muted-foreground shrink-0 text-sm"
                >{check.done
                  ? t.formUi.stateDone
                  : check.done === false
                    ? t.formUi.stateOpen
                    : t.formUi.stateCheck}</span
              >
              <span aria-hidden="true" class="text-muted-foreground"
                ><NavIcon name="chevron" size={14} /></span
              >
            </a>
          </li>
        {/each}
      </ul>
    </Panel>
    <Panel title={t.formUi.publishAction} description={t.admin.publish.intro}>
      <div class="flex max-w-md flex-col gap-4">
        <label class="flex min-h-11 items-start gap-3 text-sm">
          <Checkbox bind:checked={confirmed} disabled={busy || conflict} class="mt-0.5" />
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
                class="text-muted-foreground mt-2 text-sm"
              >
                {t.formUi.publishDisabledReason}
              </p>{/if}
          </div>
        {/if}
        {#if canBump}<div class="flex flex-col gap-1">
            <div>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                class="-ml-2.5"
                disabled={editor.saving || busy}
                onclick={() => void bump()}>{t.admin.publish.bump}</Button
              >
            </div>
            <p class="text-muted-foreground m-0 text-xs">{t.admin.publish.bumpHint}</p>
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
