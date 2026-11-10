<script lang="ts">
  import { onMount } from 'svelte';
  import { t } from '$lib/i18n';
  import { adminApi } from '$lib/api';
  import type { MailConnectionInfo, MailDelivery } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import { fieldList, formOf, setMail } from '$lib/draft/doc';
  import {
    formToMail,
    mailToForm,
    validateMailForm,
    emptyMailForm,
    emptyDerivedRule,
    type MailForm,
  } from '$lib/draft/mail';
  import { describeError } from '$lib/admin/describe';
  import { handleSessionError } from '$lib/admin/guard.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import { Checkbox } from '$lib/components/ui/checkbox';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import DraftGate from './DraftGate.svelte';

  let {
    editor,
    tenant,
    form,
    canAssign = false,
    ondirty = () => {},
  }: {
    editor: Editor;
    tenant: string;
    form: string;
    canAssign?: boolean;
    ondirty?: (value: boolean) => void;
  } = $props();

  let connections = $state<MailConnectionInfo[] | null>(null);
  // svelte-ignore state_referenced_locally
  let connection = $state(editor.detail?.mailConnectionId ?? '');
  let connMessage = $state('');
  let connOk = $state('');
  let deliveries = $state<MailDelivery[] | null>(null);

  let f = $state<MailForm>(emptyMailForm());
  let loadedFor = '';
  let errors = $state<Record<string, string | undefined>>({});
  let ok = $state('');
  let changed = $state(false);
  let connLoading = $state(false);
  let deliveryLoading = $state(false);
  let deliveryError = $state('');
  let assigning = $state(false);
  let slow = $state(false);
  let placeholder = $state('');
  $effect(() => {
    ondirty(changed);
  });
  $effect(() => () => ondirty(false));
  $effect(() => {
    if (connLoading || deliveryLoading || assigning || editor.saving) {
      const timer = setTimeout(() => (slow = true), 5000);
      return () => clearTimeout(timer);
    }
    slow = false;
  });
  async function loadConnections(): Promise<void> {
    connLoading = true;
    connMessage = '';
    const c = await adminApi.tenantConnections(tenant);
    connLoading = false;
    if (c.ok) connections = c.data.items;
    else if (!handleSessionError(c.error)) connMessage = describeError(c.error);
  }
  async function loadDeliveries(): Promise<void> {
    deliveryLoading = true;
    deliveryError = '';
    const d = await adminApi.deliveries(tenant, form);
    deliveryLoading = false;
    if (d.ok) deliveries = d.data.items;
    else if (!handleSessionError(d.error)) deliveryError = describeError(d.error);
  }
  function insert(target: 'organisation' | 'confirmation'): void {
    if (!placeholder) return;
    f[target].body += '#=[' + placeholder + ']=#';
    changed = true;
  }

  const names = $derived(editor.draft ? fieldList(editor.draft.document).map((x) => x.name) : []);
  const derivedNames = $derived(f.derived.map((d) => d.name.trim()).filter(Boolean));

  // Load the form state once per draft revision (own saves reload it with the canonical document).
  $effect(() => {
    const d = editor.draft;
    if (!d) return;
    const key = `${d.id}:${d.revision}`;
    if (key === loadedFor) return;
    loadedFor = key;
    f = mailToForm(formOf(d.document).mail);
  });

  async function saveConnection(): Promise<void> {
    connMessage = '';
    connOk = '';
    if (!connection || assigning || !canAssign) return;
    assigning = true;
    const r = await adminApi.setMailConnection(tenant, form, connection);
    assigning = false;
    if (!r.ok) {
      if (!handleSessionError(r.error)) connMessage = describeError(r.error);
      return;
    }
    connOk = t.admin.mail.connectionSaved;
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    ok = '';
    const e = validateMailForm(f, names);
    errors = e;
    if (Object.keys(e).length > 0) return;
    const mail = formToMail(f);
    const err = await editor.apply((d) => setMail(d, mail));
    if (!err) {
      ok = t.admin.saved;
      changed = false;
    }
  }

  const problem = (key: string): string | undefined => {
    const code = errors[key];
    return code ? t.admin.mail.problems[code as keyof typeof t.admin.mail.problems] : undefined;
  };

  onMount(() => {
    void loadConnections();
    void loadDeliveries();
  });
</script>

<h2 class="text-xl leading-snug font-semibold tracking-tight">{t.formWork.mail}</h2>
<p class="text-muted-foreground max-w-prose text-sm">{t.admin.mail.intro}</p>

<p class="text-muted-foreground max-w-prose text-sm">{t.formWork.routeHint}</p>
{#if slow}<p role="status">{t.formWork.slow}</p>{/if}
<div class="flex max-w-md flex-col gap-3" aria-busy={connLoading || assigning}>
  {#if connLoading}<p role="status" class="min-h-20">{t.admin.loading}</p>
  {:else if connections === null}<Notice message={connMessage} />
    <div>
      <Button variant="outline" onclick={() => void loadConnections()}>{t.admin.retry}</Button>
    </div>
  {:else if connections !== null && connections.length === 0}
    <p>{t.formWork.noRoute} {t.formWork.contactAdmin}</p>
  {:else}
    <Row id="mail-connection" label={t.admin.mail.connection}>
      <Select id="mail-connection" bind:value={connection} disabled={!canAssign || assigning}>
        <option value="" disabled>{t.admin.mail.noConnection}</option>
        {#each connections ?? [] as c (c.id)}<option value={c.id}
            >{c.name} ({t.admin.connections.kinds[c.kind]})</option
          >{/each}
      </Select>
    </Row>
  {/if}
  {#if connections && connections.length > 0 && canAssign}<div>
      <Button disabled={!connection || assigning} onclick={() => void saveConnection()}
        >{t.formWork.saveRoute}</Button
      >
    </div>{/if}
  {#if !canAssign}<p class="text-muted-foreground text-sm">{t.formWork.contactAdmin}</p>{/if}
  <Notice
    message={connections === null ? '' : connMessage || connOk}
    kind={connMessage ? 'error' : 'ok'}
  />
</div>

<DraftGate {editor}>
  <form
    onsubmit={(e) => void save(e)}
    oninput={() => (changed = true)}
    onchange={() => (changed = true)}
    class="flex max-w-xl flex-col gap-4"
  >
    <fieldset disabled={editor.saving} class="contents">
      <Row id="mail-placeholder" label={t.formWork.insert}>
        <Select id="mail-placeholder" bind:value={placeholder}
          ><option value="">{t.admin.mail.none}</option
          >{#each [...names, ...derivedNames] as name (name)}<option value={name}>{name}</option
            >{/each}</Select
        >
      </Row>
      <div class="flex flex-wrap gap-2">
        <Button
          variant="outline"
          disabled={!placeholder || !f.organisation.enabled}
          onclick={() => insert('organisation')}>{t.formWork.insertTeam}</Button
        ><Button
          variant="outline"
          disabled={!placeholder || !f.confirmation.enabled}
          onclick={() => insert('confirmation')}>{t.formWork.insertConfirmation}</Button
        >
      </div>
      <Row id="mail-from" label={t.admin.mail.fromAddress} error={problem('fromAddress')}>
        <Input
          id="mail-from"
          aria-invalid={!!problem('fromAddress')}
          aria-describedby={problem('fromAddress') ? 'mail-from-error' : undefined}
          type="email"
          bind:value={f.fromAddress}
          autocomplete="off"
        />
      </Row>
      <Row id="mail-from-name" label={t.admin.mail.fromName}>
        <Input id="mail-from-name" bind:value={f.fromName} maxlength={100} autocomplete="off" />
      </Row>

      <fieldset class="border-border flex flex-col gap-3 rounded-lg border p-4">
        <legend class="px-1 font-medium"
          ><label class="flex items-center gap-2"
            ><Checkbox bind:checked={f.organisation.enabled} />{t.admin.mail.orgEnabled}</label
          ></legend
        >
        {#if f.organisation.enabled}
          <Row id="org-to" label={t.admin.mail.orgTo} error={problem('orgTo')}
            ><Textarea
              id="org-to"
              aria-invalid={!!problem('orgTo')}
              aria-describedby={problem('orgTo') ? 'org-to-error' : undefined}
              bind:value={f.organisation.to}
            /></Row
          >
          <Row id="org-bcc" label={t.admin.mail.orgBcc} error={problem('orgBcc')}
            ><Textarea
              id="org-bcc"
              aria-invalid={!!problem('orgBcc')}
              aria-describedby={problem('orgBcc') ? 'org-bcc-error' : undefined}
              bind:value={f.organisation.bcc}
              class="min-h-12"
            /></Row
          >
          <Row id="org-reply" label={t.admin.mail.replyTo}>
            <Select id="org-reply" bind:value={f.organisation.replyToField}>
              <option value="">{t.admin.mail.none}</option>
              {#each names as n (n)}<option value={n}>{n}</option>{/each}
            </Select>
          </Row>
          <Row id="org-subject" label={t.admin.mail.subject} error={problem('orgSubject')}
            ><Input
              id="org-subject"
              aria-invalid={!!problem('orgSubject')}
              aria-describedby={problem('orgSubject') ? 'org-subject-error' : undefined}
              bind:value={f.organisation.subject}
            /></Row
          >
          <Row
            id="org-body"
            label={t.admin.mail.body}
            hint={t.admin.mail.bodyHint}
            error={problem('orgBody')}
            ><Textarea
              id="org-body"
              aria-invalid={!!problem('orgBody')}
              aria-describedby={problem('orgBody') ? 'org-body-error' : undefined}
              bind:value={f.organisation.body}
              class="min-h-40"
            /></Row
          >
          <Row id="org-format" label={t.admin.mail.format}>
            <Select id="org-format" bind:value={f.organisation.format}>
              <option value="text">{t.admin.mail.formatText}</option><option value="html"
                >{t.admin.mail.formatHtml}</option
              >
            </Select>
          </Row>
        {/if}
      </fieldset>

      <fieldset class="border-border flex flex-col gap-3 rounded-lg border p-4">
        <legend class="px-1 font-medium">{t.admin.mail.derived.title}</legend>
        <p class="text-muted-foreground max-w-prose text-sm">{t.admin.mail.derived.hint}</p>
        {#if problem('derived')}<p role="alert" class="text-destructive text-sm">
            {problem('derived')}
          </p>{/if}
        {#each f.derived as rule, index (index)}
          <div class="border-border grid gap-2 rounded-md border p-3 sm:grid-cols-2">
            <Row id={`derived-name-${index}`} label={t.admin.mail.derived.name}>
              <Input
                id={`derived-name-${index}`}
                bind:value={rule.name}
                maxlength={64}
                autocomplete="off"
              />
            </Row>
            <Row id={`derived-op-${index}`} label={t.admin.mail.derived.op}>
              <Select id={`derived-op-${index}`} bind:value={rule.op}>
                {#each ['join', 'firstNonEmpty', 'date', 'now'] as op (op)}
                  <option value={op}>{t.admin.mail.derived.ops[op as 'join']}</option>
                {/each}
              </Select>
            </Row>
            {#if rule.op === 'join' || rule.op === 'firstNonEmpty'}
              <Row id={`derived-fields-${index}`} label={t.admin.mail.derived.fields}>
                <Textarea
                  id={`derived-fields-${index}`}
                  bind:value={rule.fields}
                  class="min-h-12"
                />
              </Row>
            {/if}
            {#if rule.op === 'join'}
              <Row id={`derived-sep-${index}`} label={t.admin.mail.derived.separator}>
                <Input id={`derived-sep-${index}`} bind:value={rule.separator} maxlength={10} />
              </Row>
            {/if}
            {#if rule.op === 'date'}
              <Row id={`derived-field-${index}`} label={t.admin.mail.derived.sourceField}>
                <Select id={`derived-field-${index}`} bind:value={rule.field}>
                  <option value="" disabled>{t.admin.mail.none}</option>
                  {#each names as n (n)}<option value={n}>{n}</option>{/each}
                </Select>
              </Row>
            {/if}
            {#if rule.op === 'date' || rule.op === 'now'}
              <Row id={`derived-format-${index}`} label={t.admin.mail.derived.format}>
                <Input id={`derived-format-${index}`} bind:value={rule.format} maxlength={40} />
              </Row>
            {/if}
            <div class="sm:col-span-2">
              <Button
                variant="ghost"
                onclick={() => {
                  f.derived = f.derived.filter((_, i) => i !== index);
                  changed = true;
                }}>{t.admin.mail.derived.remove}</Button
              >
            </div>
          </div>
        {/each}
        <div>
          <Button
            variant="outline"
            onclick={() => {
              f.derived = [...f.derived, emptyDerivedRule()];
              changed = true;
            }}>{t.admin.mail.derived.add}</Button
          >
        </div>
      </fieldset>

      <fieldset class="border-border flex flex-col gap-3 rounded-lg border p-4">
        <legend class="px-1 font-medium"
          ><label class="flex items-center gap-2"
            ><Checkbox bind:checked={f.confirmation.enabled} />{t.admin.mail.confEnabled}</label
          ></legend
        >
        {#if f.confirmation.enabled}
          <Row id="conf-to" label={t.admin.mail.confTo} error={problem('confToField')}>
            <Select
              id="conf-to"
              aria-invalid={!!problem('confToField')}
              aria-describedby={problem('confToField') ? 'conf-to-error' : undefined}
              bind:value={f.confirmation.toField}
            >
              <option value="" disabled>{t.admin.mail.none}</option>
              {#each names as n (n)}<option value={n}>{n}</option>{/each}
            </Select>
          </Row>
          <Row id="conf-subject" label={t.admin.mail.subject} error={problem('confSubject')}
            ><Input
              id="conf-subject"
              aria-invalid={!!problem('confSubject')}
              aria-describedby={problem('confSubject') ? 'conf-subject-error' : undefined}
              bind:value={f.confirmation.subject}
            /></Row
          >
          <Row
            id="conf-body"
            label={t.admin.mail.body}
            hint={t.admin.mail.bodyHint}
            error={problem('confBody')}
            ><Textarea
              id="conf-body"
              aria-invalid={!!problem('confBody')}
              aria-describedby={problem('confBody') ? 'conf-body-error' : undefined}
              bind:value={f.confirmation.body}
              class="min-h-40"
            /></Row
          >
          <Row id="conf-format" label={t.admin.mail.format}>
            <Select id="conf-format" bind:value={f.confirmation.format}>
              <option value="text">{t.admin.mail.formatText}</option><option value="html"
                >{t.admin.mail.formatHtml}</option
              >
            </Select>
          </Row>
        {/if}
      </fieldset>

      <p class="text-muted-foreground text-xs">{t.admin.mail.saveHint}</p>
      <Notice
        message={editor.error
          ? editor.error.status === 409
            ? t.formWork.conflict
            : describeError(editor.error)
          : ok}
        kind={editor.error ? 'error' : 'ok'}
      />
      {#if editor.error?.status === 409}<div>
          <Button
            variant="outline"
            onclick={() => {
              if (!changed || confirm(t.formWork.unsaved)) {
                changed = false;
                void editor.load();
              }
            }}>{t.formWork.reload}</Button
          >
        </div>{/if}
      <div><Button type="submit" disabled={editor.saving}>{t.admin.save}</Button></div>
    </fieldset>
  </form>
</DraftGate>

<h2 class="mt-8 text-xl leading-snug font-semibold tracking-tight">{t.admin.mail.deliveries}</h2>
<p class="text-muted-foreground text-sm">{t.formWork.acceptedHint}</p>
{#if deliveryError}<Notice message={deliveryError} />
  <div>
    <Button variant="outline" onclick={() => void loadDeliveries()}>{t.admin.retry}</Button>
  </div>
{:else if deliveryLoading || deliveries === null}
  <p role="status" aria-busy="true" class="min-h-32">{t.admin.loading}</p>
{:else if deliveries.length === 0}
  <p>{t.admin.mail.noDeliveries}</p>
{:else}
  <div class="overflow-x-auto">
    <table class="w-full text-left text-sm">
      <thead
        ><tr class="border-border border-b"
          ><th class="py-2 pr-4"
            >{t.admin.mail.kinds.organisation}/{t.admin.mail.kinds.confirmation}</th
          ><th class="pr-4">{t.formWork.status}</th><th class="pr-4">{t.formWork.attempts}</th><th
            >{t.formWork.time}</th
          ></tr
        ></thead
      >
      <tbody>
        {#each deliveries as d (d.id)}
          <tr class="border-border border-b">
            <td class="py-2 pr-4">{t.admin.mail.kinds[d.kind]}</td>
            <td class="pr-4"
              >{t.admin.mail.states[d.state] ?? d.state}{d.errorCode ? ` (${d.errorCode})` : ''}</td
            >
            <td class="pr-4">{d.attempts}</td>
            <td
              ><time datetime={d.updatedAt}>{new Date(d.updatedAt).toLocaleString('de-DE')}</time
              ></td
            >
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
{/if}
