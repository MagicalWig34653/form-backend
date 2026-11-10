<script lang="ts">
  import { t } from '$lib/i18n';
  import { http } from '$lib/api';
  import { describeError } from '$lib/admin/describe';
  import { formOf } from '$lib/draft/doc';
  import type { JsonObject } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Row from '$lib/components/admin/Row.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import SaveBar from '$lib/components/admin/SaveBar.svelte';
  import SaveStatus from '$lib/components/admin/SaveStatus.svelte';
  let {
    editor,
    tenant,
    form,
    ondirty = () => {},
  }: {
    editor: Editor;
    tenant: string;
    form: string;
    ondirty?: (value: boolean) => void;
  } = $props();
  let changed = $state(false);
  $effect(() => {
    ondirty(changed);
  });
  $effect(() => () => ondirty(false));
  let siteKey = $state('');
  let secret = $state('');
  let closed = $state(false);
  let testMode = $state(false);
  let notice = $state('');
  let noticeKind = $state<'ok' | 'error'>('ok');
  const formId = 'abuse-form';
  let busy = $state(false);
  let savedAt = $state<Date | null>(null);
  const text = t.abuse;
  $effect(() => {
    if (changed) return;
    const security = formOf(editor.draft?.document ?? {}).security as JsonObject | undefined;
    const policy = security?.abuse as JsonObject | undefined;
    siteKey = String(policy?.siteKey ?? '');
    closed = policy?.failPolicy === 'closed';
    testMode = policy?.testMode === true;
  });
  function discard(): void {
    secret = '';
    notice = '';
    changed = false;
  }
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (!editor.draft || busy) return;
    busy = true;
    notice = '';
    noticeKind = 'ok';
    if (secret) {
      const result = await http.request('PUT', `/tenants/${tenant}/forms/${form}/abuse-secret`, {
        body: { secret },
      });
      secret = '';
      if (!result.ok) {
        notice = describeError(result.error);
        noticeKind = 'error';
        busy = false;
        return;
      }
    }
    const error = await editor.apply((doc) => {
      const next = JSON.parse(JSON.stringify(doc)) as JsonObject;
      const target = formOf(next);
      const security = target.security as JsonObject;
      security.abuse = {
        ...(siteKey ? { siteKey } : {}),
        failPolicy: closed ? 'closed' : 'open',
        testMode,
      };
      return next;
    });
    if (!error) changed = false;
    noticeKind = error ? 'error' : 'ok';
    if (!error) savedAt = new Date();
    notice = error ? describeError(error) : '';
    busy = false;
  }
</script>

<Panel title={text.title} description={text.help} hint={text.saveHint}>
  {#snippet actions()}
    <SaveStatus
      state={busy
        ? 'saving'
        : noticeKind === 'error' && notice
          ? 'error'
          : changed
            ? 'dirty'
            : savedAt
              ? 'saved'
              : 'idle'}
      at={savedAt}
      error={noticeKind === 'error' ? notice : ''}
      idle={t.saveStatus.idle}
    />
  {/snippet}
  {#if testMode}<div class="mb-4"><Banner tone="warn">{text.testWarning}</Banner></div>{/if}
  <form
    id={formId}
    onsubmit={save}
    oninput={() => (changed = true)}
    onchange={() => (changed = true)}
    class="flex max-w-[560px] flex-col gap-4"
  >
    <details class="text-muted-foreground text-sm">
      <summary class="min-h-8 cursor-pointer py-1 font-medium">{text.detailsTitle}</summary>
      <p class="mt-2 mb-0">{text.details}</p>
    </details>
    <Row id="abuse-site-key" optional label={text.siteKey}>
      <Input id="abuse-site-key" bind:value={siteKey} maxlength={100} />
    </Row>
    <Row id="abuse-secret" optional label={text.secret}>
      <Input
        id="abuse-secret"
        type="password"
        bind:value={secret}
        maxlength={200}
        autocomplete="new-password"
      />
    </Row>
    <fieldset class="m-0 flex flex-col gap-1 border-0 p-0">
      <legend class="mb-1 text-sm font-medium">{t.formWork.behavior}</legend>
      <label class="flex min-h-10 items-center gap-3 text-sm"
        ><Checkbox bind:checked={closed} />{text.closed}</label
      >
      <label class="flex min-h-10 items-center gap-3 text-sm"
        ><Checkbox bind:checked={testMode} />{text.test}</label
      >
    </fieldset>
  </form>
</Panel>
<SaveBar
  dirty={changed}
  busy={busy || editor.saving}
  form={formId}
  ondiscard={discard}
  status=""
  saveLabel={text.save}
/>
