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
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
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

<Panel title={text.title} description={text.help}>
  {#if testMode}<div class="mb-4"><Banner tone="warn">{text.testWarning}</Banner></div>{/if}
  <form
    onsubmit={save}
    oninput={() => (changed = true)}
    onchange={() => (changed = true)}
    class="flex max-w-xl flex-col gap-4"
  >
    <Row id="abuse-site-key" label={text.siteKey}>
      <Input id="abuse-site-key" bind:value={siteKey} maxlength={100} />
    </Row>
    <Row id="abuse-secret" label={text.secret}>
      <Input
        id="abuse-secret"
        type="password"
        bind:value={secret}
        maxlength={200}
        autocomplete="new-password"
      />
    </Row>
    <label class="flex min-h-8 items-center gap-2 text-sm"
      ><Checkbox bind:checked={closed} />{text.closed}</label
    >
    <label class="flex min-h-8 items-center gap-2 text-sm"
      ><Checkbox bind:checked={testMode} />{text.test}</label
    >
    <div>
      <Button type="submit" disabled={!editor.draft || busy || editor.saving}>{text.save}</Button>
    </div>
  </form>
  {#if notice}<p role="status" class="mt-3 text-sm">{notice}</p>{/if}
</Panel>
