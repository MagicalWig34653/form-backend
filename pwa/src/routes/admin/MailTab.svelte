<script lang="ts">
  import { formatDateTime } from '$lib/format';
  import { confirmDiscard } from '$lib/confirm.svelte';
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
  import { Switch } from '$lib/components/ui/switch';
  import Panel from '$lib/components/admin/Panel.svelte';
  import Banner from '$lib/components/admin/Banner.svelte';
  import EmptyState from '$lib/components/admin/EmptyState.svelte';
  import SaveBar from '$lib/components/admin/SaveBar.svelte';
  import SaveStatus from '$lib/components/admin/SaveStatus.svelte';
  import StatusChip from '$lib/components/admin/StatusChip.svelte';
  import { router } from '$lib/router.svelte';
  import { session } from '$lib/session.svelte';
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
  // svelte-ignore state_referenced_locally
  let assigned = $state(editor.detail?.mailConnectionId ?? '');
  const assignedName = $derived(connections?.find((c) => c.id === assigned)?.name ?? '');
  /** A way is picked in the list but not yet assigned: only "Versandweg zuweisen" makes it effective. */
  const pending = $derived(connection !== '' && connection !== assigned);
  let connMessage = $state('');
  let connOk = $state('');
  let deliveries = $state<MailDelivery[] | null>(null);

  let f = $state<MailForm>(emptyMailForm());
  let loadedFor = '';
  let errors = $state<Record<string, string | undefined>>({});
  let changed = $state(false);
  let connLoading = $state(false);
  let deliveryLoading = $state(false);
  let deliveryError = $state('');
  let assigning = $state(false);
  let slow = $state(false);
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
    if (c.ok) {
      connections = c.data.items;
    } else if (!handleSessionError(c.error)) connMessage = describeError(c.error);
  }
  async function loadDeliveries(): Promise<void> {
    deliveryLoading = true;
    deliveryError = '';
    const d = await adminApi.deliveries(tenant, form);
    deliveryLoading = false;
    if (d.ok) deliveries = d.data.items;
    else if (!handleSessionError(d.error)) deliveryError = describeError(d.error);
  }
  /** Body that receives a chosen placeholder: the one edited last. */
  let target = $state<'organisation' | 'confirmation'>('organisation');
  function insert(name: string): void {
    f[target].body += '#=[' + name + ']=#';
    changed = true;
  }
  function goConnections(event: MouseEvent): void {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    router.navigate('/connections');
  }

  const names = $derived(editor.draft ? fieldList(editor.draft.document).map((x) => x.name) : []);
  // Required details still missing or invalid, per template (shown in the section header).
  const problems = $derived(validateMailForm(f, names));
  const missing = (keys: string[]): number => keys.filter((k) => problems[k]).length;
  const orgMissing = $derived(
    f.organisation.enabled ? missing(['orgTo', 'orgBcc', 'orgSubject', 'orgBody']) : 0,
  );
  const confMissing = $derived(
    f.confirmation.enabled ? missing(['confToField', 'confSubject', 'confBody']) : 0,
  );
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

  function discard(): void {
    changed = false;
    loadedFor = '';
    void editor.load();
  }

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
    assigned = connection;
    connOk = t.admin.mail.connectionSaved;
  }

  async function save(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const e = validateMailForm(f, names);
    errors = e;
    if (Object.keys(e).length > 0) return;
    const mail = formToMail(f);
    const err = await editor.apply((d) => setMail(d, mail));
    if (!err) {
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

<Panel title={t.formWork.routeTitle} description={t.formWork.routeHint}>
  {#snippet actions()}
    {#if connections !== null}
      {#if assigned}<StatusChip
          tone="ok"
          label={assignedName
            ? t.formWork.routeAssigned.replace('{name}', assignedName)
            : t.formWork.routeAssignedShort}
        />{:else}<StatusChip tone="warn" label={t.formWork.routeNone} />{/if}
    {/if}
  {/snippet}
  <div class="flex flex-col gap-4" aria-busy={connLoading || assigning}>
    {#if slow}<p role="status" class="text-muted-foreground m-0 text-sm">{t.formWork.slow}</p>{/if}
    {#if connLoading}<p role="status" class="text-muted-foreground m-0 min-h-10 text-sm">
        {t.admin.loading}
      </p>
    {:else if connections === null}
      <Notice message={connMessage} />
      <div>
        <Button variant="outline" onclick={() => void loadConnections()}>{t.admin.retry}</Button>
      </div>
    {:else if connections.length === 0}
      <Banner tone="warn" title={t.formWork.noRoute}>
        {session.me?.systemAdministrator ? t.formWork.assignAdmin : t.formWork.contactAdmin}
        {#snippet action()}
          {#if session.me?.systemAdministrator}
            <Button variant="outline" href="/connections" onclick={goConnections}
              >{t.formWork.toConnections}</Button
            >
          {/if}
        {/snippet}
      </Banner>
    {:else}
      <div class="max-w-[560px]">
        <Row id="mail-connection" label={t.admin.mail.connection}>
          <Select id="mail-connection" bind:value={connection} disabled={!canAssign || assigning}>
            <option value="" disabled>{t.admin.mail.noConnection}</option>
            {#each connections ?? [] as c (c.id)}<option value={c.id}
                >{c.name} ({t.admin.connections.kinds[c.kind]})</option
              >{/each}
          </Select>
        </Row>
      </div>
      {#if pending}<p class="text-muted-foreground m-0 text-sm" id="mail-connection-pending">
          {t.formWork.routePending}
        </p>{/if}
      {#if canAssign}<div>
          <Button disabled={!pending || assigning} onclick={() => void saveConnection()}
            >{t.formWork.saveRoute}</Button
          >
        </div>{:else}<p class="text-muted-foreground m-0 text-sm">{t.formWork.contactAdmin}</p>{/if}
    {/if}
    <Notice
      message={connections === null ? '' : connMessage || connOk}
      kind={connMessage ? 'error' : 'ok'}
    />
  </div>
</Panel>

{#snippet chips(kind: 'organisation' | 'confirmation')}
  <div class="flex flex-col gap-1.5" role="group" aria-label={t.formWork.insert}>
    <span class="text-sm leading-5 font-medium">{t.formWork.insert}</span>
    <div class="flex flex-wrap gap-1.5">
      {#each [...names, ...derivedNames] as name (name)}
        <Button
          type="button"
          variant="outline"
          size="sm"
          onclick={() => {
            target = kind;
            insert(name);
          }}>{name}</Button
        >
      {:else}
        <span class="text-muted-foreground text-sm">{t.admin.mail.none}</span>
      {/each}
    </div>
    <p class="text-muted-foreground m-0 text-xs">{t.admin.mail.bodyHint}</p>
  </div>
{/snippet}

<DraftGate {editor} hint={false}>
  <Panel
    title={t.admin.mail.templateTitle}
    description={t.admin.mail.intro}
    hint={t.admin.mail.saveHint}
  >
    {#snippet actions()}
      <SaveStatus
        state={editor.saving
          ? 'saving'
          : editor.error
            ? 'error'
            : changed
              ? 'dirty'
              : editor.savedAt
                ? 'saved'
                : 'idle'}
        at={editor.savedAt}
        error={editor.error
          ? editor.error.status === 409
            ? t.formWork.conflict
            : describeError(editor.error)
          : ''}
        idle={t.saveStatus.idle}
      />
    {/snippet}
    <form
      id="mail-form"
      onsubmit={(e) => void save(e)}
      oninput={() => (changed = true)}
      onchange={() => (changed = true)}
      class="flex max-w-[560px] flex-col gap-5"
    >
      <fieldset disabled={editor.saving} class="m-0 flex min-w-0 flex-col gap-5 border-0 p-0">
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
        <Row id="mail-from-name" optional label={t.admin.mail.fromName}>
          <Input id="mail-from-name" bind:value={f.fromName} maxlength={100} autocomplete="off" />
        </Row>

        <section
          class="border-border flex flex-col gap-4 border-t pt-5"
          aria-labelledby="mail-sec-org"
        >
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
              <h3 id="mail-sec-org" class="m-0 text-base font-semibold">
                {t.admin.mail.kinds.organisation}
              </h3>
              {#if orgMissing > 0}<StatusChip
                  tone="warn"
                  label={t.admin.mail.missing.replace('{n}', String(orgMissing))}
                />{/if}
            </div>
            <label class="flex min-h-10 items-center gap-3 text-sm font-medium"
              ><Switch bind:checked={f.organisation.enabled} />{t.admin.mail.orgEnabled}</label
            >
          </div>
          {#if f.organisation.enabled}
            <details open class="flex flex-col gap-4">
              <summary class="text-muted-foreground min-h-8 cursor-pointer text-sm font-medium"
                >{t.admin.mail.templateDetails}</summary
              >
              <div class="flex flex-col gap-4">
                <Row id="org-to" label={t.admin.mail.orgTo} error={problem('orgTo')}
                  ><Textarea
                    id="org-to"
                    aria-invalid={!!problem('orgTo')}
                    aria-describedby={problem('orgTo') ? 'org-to-error' : undefined}
                    bind:value={f.organisation.to}
                  /></Row
                >
                <Row id="org-bcc" optional label={t.admin.mail.orgBcc} error={problem('orgBcc')}
                  ><Textarea
                    id="org-bcc"
                    aria-invalid={!!problem('orgBcc')}
                    aria-describedby={problem('orgBcc') ? 'org-bcc-error' : undefined}
                    bind:value={f.organisation.bcc}
                    class="min-h-12"
                  /></Row
                >
                <Row id="org-reply" optional label={t.admin.mail.replyTo}>
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
                {@render chips('organisation')}
                <Row id="org-body" label={t.admin.mail.body} error={problem('orgBody')}
                  ><Textarea
                    id="org-body"
                    aria-invalid={!!problem('orgBody')}
                    aria-describedby={problem('orgBody') ? 'org-body-error' : undefined}
                    bind:value={f.organisation.body}
                    onfocus={() => (target = 'organisation')}
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
              </div>
            </details>
          {/if}
        </section>

        <details class="border-border border-t pt-4" open={f.derived.length > 0}>
          <summary class="min-h-10 cursor-pointer py-2 text-sm font-semibold"
            >{t.admin.mail.derived.title}</summary
          >
          <p class="text-muted-foreground mt-1 mb-3 max-w-prose text-sm">
            {t.admin.mail.derived.hint}
          </p>
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
        </details>

        <section
          class="border-border flex flex-col gap-4 border-t pt-5"
          aria-labelledby="mail-sec-conf"
        >
          <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-2">
            <div class="flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1">
              <h3 id="mail-sec-conf" class="m-0 text-base font-semibold">
                {t.admin.mail.kinds.confirmation}
              </h3>
              {#if confMissing > 0}<StatusChip
                  tone="warn"
                  label={t.admin.mail.missing.replace('{n}', String(confMissing))}
                />{/if}
            </div>
            <label class="flex min-h-10 items-center gap-3 text-sm font-medium"
              ><Switch bind:checked={f.confirmation.enabled} />{t.admin.mail.confEnabled}</label
            >
          </div>
          {#if f.confirmation.enabled}
            <details open class="flex flex-col gap-4">
              <summary class="text-muted-foreground min-h-8 cursor-pointer text-sm font-medium"
                >{t.admin.mail.templateDetails}</summary
              >
              <div class="flex flex-col gap-4">
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
                {@render chips('confirmation')}
                <Row id="conf-body" label={t.admin.mail.body} error={problem('confBody')}
                  ><Textarea
                    id="conf-body"
                    aria-invalid={!!problem('confBody')}
                    aria-describedby={problem('confBody') ? 'conf-body-error' : undefined}
                    bind:value={f.confirmation.body}
                    onfocus={() => (target = 'confirmation')}
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
              </div>
            </details>
          {/if}
        </section>

        {#if editor.error?.status === 409}<div>
            <Button
              variant="outline"
              onclick={async () => {
                if (!changed || (await confirmDiscard())) {
                  changed = false;
                  void editor.load();
                }
              }}>{t.formWork.reload}</Button
            >
          </div>{/if}
      </fieldset>
    </form>
  </Panel>
  <SaveBar dirty={changed} busy={editor.saving} form="mail-form" ondiscard={discard} status="" />
</DraftGate>

<Panel title={t.admin.mail.deliveries} description={t.formWork.acceptedHint}>
  {#if deliveryError}
    <Notice message={deliveryError} />
    <div class="mt-2">
      <Button variant="outline" onclick={() => void loadDeliveries()}>{t.admin.retry}</Button>
    </div>
  {:else if deliveryLoading || deliveries === null}
    <p role="status" aria-busy="true" class="text-muted-foreground m-0 min-h-10 text-sm">
      {t.admin.loading}
    </p>
  {:else if deliveries.length === 0}
    <EmptyState icon="inbox" title={t.admin.mail.noDeliveries} class="py-6" />
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
                >{t.admin.mail.states[d.state] ?? d.state}{d.errorCode
                  ? ` (${d.errorCode})`
                  : ''}</td
              >
              <td class="pr-4">{d.attempts}</td>
              <td><time datetime={d.updatedAt}>{formatDateTime(d.updatedAt)}</time></td>
            </tr>
          {/each}
        </tbody>
      </table>
    </div>
  {/if}
</Panel>
