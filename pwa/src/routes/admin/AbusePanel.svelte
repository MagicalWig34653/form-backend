<script lang="ts">
  import { t } from '$lib/i18n';
  import { http } from '$lib/api';
  import { describeError } from '$lib/admin/describe';
  import { formOf } from '$lib/draft/doc';
  import type { JsonObject } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
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
  let busy = $state(false);
  const text = t.abuse;
  $effect(() => {
    if (changed) return;
    const security = formOf(editor.draft?.document ?? {}).security as JsonObject | undefined;
    const policy = security?.abuse as JsonObject | undefined;
    siteKey = String(policy?.siteKey ?? '');
    closed = policy?.failPolicy === 'closed';
    testMode = policy?.testMode === true;
  });
  async function save(event: SubmitEvent) {
    event.preventDefault();
    if (!editor.draft || busy) return;
    busy = true;
    notice = '';
    if (secret) {
      const result = await http.request('PUT', `/tenants/${tenant}/forms/${form}/abuse-secret`, {
        body: { secret },
      });
      secret = '';
      if (!result.ok) {
        notice = describeError(result.error);
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
    notice = error ? describeError(error) : text.saved;
    busy = false;
  }
</script>

<section class="rounded-lg border p-4">
  <h2>{text.title}</h2>
  <p>{text.help}</p>
  {#if testMode}<p role="status">{text.testWarning}</p>{/if}
  <form
    onsubmit={save}
    oninput={() => (changed = true)}
    onchange={() => (changed = true)}
    class="flex flex-col gap-3"
  >
    <label>{text.siteKey}<input bind:value={siteKey} maxlength="100" /></label>
    <label
      >{text.secret}<input
        type="password"
        bind:value={secret}
        maxlength="200"
        autocomplete="new-password"
      /></label
    >
    <label><input type="checkbox" bind:checked={closed} />{text.closed}</label>
    <label><input type="checkbox" bind:checked={testMode} />{text.test}</label>
    <button disabled={!editor.draft || busy || editor.saving}>{text.save}</button>
  </form>
  {#if notice}<p role="status">{notice}</p>{/if}
</section>
