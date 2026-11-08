<script lang="ts">
  import { t } from '$lib/i18n';
  import type { JsonObject } from '$lib/api/admin';
  import type { Editor } from '$lib/draft/editor.svelte';
  import {
    FIELD_KINDS,
    title,
    setTitle,
    formOf,
    viewsOf,
    addField,
    fieldList,
    mailReferences,
    removeField,
    updateField,
    validateFieldInput,
    type FieldInput,
    type FieldKind,
  } from '$lib/draft/doc';
  import { describeError } from '$lib/admin/describe';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Row from '$lib/components/admin/Row.svelte';
  import Select from '$lib/components/admin/Select.svelte';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import Notice from '$lib/components/admin/Notice.svelte';
  import Panel from '$lib/components/admin/Panel.svelte';
  import DraftGate from './DraftGate.svelte';

  let { editor, ondirty = () => {} }: { editor: Editor; ondirty?: (value: boolean) => void } =
    $props();

  const fields = $derived.by(() => {
    if (!editor.draft) return [];
    const order = refs(editor.draft.document).map((ref) => String(ref.fieldId));
    return fieldList(editor.draft.document).sort((a, b) => {
      const ai = order.indexOf(a.id),
        bi = order.indexOf(b.id);
      return (ai < 0 ? Infinity : ai) - (bi < 0 ? Infinity : bi);
    });
  });
  function canMove(id: string, direction: number): boolean {
    return viewsOf(editor.draft?.document ?? {}).some((view) =>
      ((view.steps ?? []) as JsonObject[]).some((step) =>
        ((step.sections ?? []) as JsonObject[]).some((section) => {
          const list = (section.fields ?? []) as JsonObject[];
          const index = list.findIndex((f) => f.fieldId === id);
          return index >= 0 && index + direction >= 0 && index + direction < list.length;
        }),
      ),
    );
  }

  // `editing` is a field id, '' for "new", null for the closed form.
  let editing = $state<string | null>(null);
  let name = $state('');
  let label = $state('');
  let kind = $state<FieldKind>('text');
  let required = $state(false);
  let optionsText = $state('');
  let problem = $state('');
  let problemFor = $state('');
  let notice = $state('');
  let preview = $state(false);
  let hidden = $state(false);
  let locked = $state(false);
  let fixedValue = $state('');
  let readOnly = $state(false);
  let disabled = $state(false);
  let changed = $state(false);
  let titleText = $state('');
  let titleChanged = $state(false);
  $effect(() => {
    if (editor.draft && !titleChanged) titleText = title(editor.draft.document);
  });
  async function saveTitle(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    const err = await editor.apply((doc) => setTitle(doc, titleText));
    if (!err) titleChanged = false;
  }
  let slow = $state(false);
  $effect(() => {
    if (editor.saving) {
      const timer = setTimeout(() => (slow = true), 5000);
      return () => clearTimeout(timer);
    }
    slow = false;
  });
  const obj = (value: unknown): JsonObject =>
    value && typeof value === 'object' ? (value as JsonObject) : {};
  function refs(doc: JsonObject): JsonObject[] {
    return viewsOf(doc).flatMap((v) =>
      ((v.steps ?? []) as JsonObject[]).flatMap((step) =>
        ((step.sections ?? []) as JsonObject[]).flatMap(
          (section) => (section.fields ?? []) as JsonObject[],
        ),
      ),
    );
  }
  $effect(() => {
    ondirty(changed || titleChanged);
  });
  $effect(() => () => ondirty(false));
  async function move(id: string, direction: number): Promise<void> {
    await editor.apply((doc) => {
      const next = JSON.parse(JSON.stringify(doc)) as JsonObject;
      for (const view of viewsOf(next))
        for (const step of (view.steps ?? []) as JsonObject[])
          for (const section of (step.sections ?? []) as JsonObject[]) {
            const list = (section.fields ?? []) as JsonObject[];
            const index = list.findIndex((f) => f.fieldId === id);
            const other = index + direction;
            if (index >= 0 && other >= 0 && other < list.length)
              [list[index], list[other]] = [list[other]!, list[index]!];
          }
      return next;
    });
  }

  function open(id: string): void {
    const f = fields.find((x) => x.id === id);
    editing = id;
    name = f?.name ?? '';
    label = f?.label ?? '';
    kind = (f?.kind as FieldKind | undefined) ?? 'text';
    required = f?.required ?? false;
    optionsText = (f?.options ?? []).join('\n');
    problem = '';
    problemFor = '';
    notice = '';
    changed = false;
    const raw = obj(obj(formOf(editor.draft?.document ?? {}).fields)[id]);
    hidden = raw.hidden === true;
    locked = raw.locked === true;
    fixedValue = String(raw.fixedValue ?? '');
    const ref = refs(editor.draft?.document ?? {}).find((f) => f.fieldId === id);
    readOnly = ref?.readOnly === true;
    disabled = ref?.disabled === true;
  }

  function input(): FieldInput {
    const options = optionsText
      .split('\n')
      .map((s) => s.trim())
      .filter((s) => s !== '');
    return {
      name: name.trim(),
      label: label.trim(),
      kind,
      required,
      ...(kind === 'choice' ? { options } : {}),
    };
  }

  async function submit(event: SubmitEvent): Promise<void> {
    event.preventDefault();
    if (!editor.draft || editing === null) return;
    const value = input();
    const why = validateFieldInput(
      editor.draft.document,
      value,
      editing === '' ? undefined : editing,
    );
    if (why) {
      problemFor = why;
      problem = t.admin.fields.problems[why];
      return;
    }
    problem = '';
    problemFor = '';
    const id = editing;
    const err = await editor.apply((d) => {
      const next = id === '' ? addField(d, value) : updateField(d, id, value);
      const fields = obj(formOf(next).fields);
      const target = id || Object.keys(fields).find((k) => obj(fields[k]).name === value.name)!;
      const old = obj(obj(formOf(d).fields)[target]);
      const updated = obj(fields[target]);
      // Keep imported validation and metadata when editing only a label or view flags.
      const previous = fieldList(d).find((f) => f.id === target);
      fields[target] = {
        ...old,
        ...updated,
        label: { ...obj(old.label), de: value.label },
        sensitive: typeof old.sensitive === 'boolean' ? old.sensitive : updated.sensitive,
        ...(previous?.kind === value.kind &&
        JSON.stringify(previous.options) === JSON.stringify(value.options ?? [])
          ? { validation: old.validation }
          : {}),
        hidden,
        locked,
      };
      if (locked)
        obj(fields[target]).fixedValue =
          id && old.locked === true && fixedValue === String(old.fixedValue ?? '')
            ? old.fixedValue
            : fixedValue;
      else delete obj(fields[target]).fixedValue;
      for (const ref of refs(next))
        if (ref.fieldId === target) {
          ref.readOnly = readOnly;
          ref.disabled = disabled;
        }
      return next;
    });
    if (!err) {
      editing = null;
      changed = false;
    }
  }

  async function remove(id: string, fieldName: string): Promise<void> {
    if (!editor.draft) return;
    const used = mailReferences(editor.draft.document, fieldName);
    if (used.length > 0) {
      notice = t.admin.fields.usedByMail.replace('{where}', used.join(', '));
      return;
    }
    if (!confirm(t.admin.fields.confirmRemove.replace('{name}', fieldName))) return;
    notice = '';
    await editor.apply((d) => removeField(d, id));
  }
  const box = 'size-6 shrink-0 accent-[var(--ui-accent)]';
</script>

<Panel title={t.formWork.fields} description={t.formUi.editorFieldsHint}>
  {#snippet actions()}
    <Button variant="outline" onclick={() => (preview = !preview)} aria-expanded={preview}
      >{t.formWork.preview}</Button
    >
  {/snippet}
  <div class="flex flex-col gap-4 pt-2">
    <DraftGate {editor}>
      {#if slow}<p role="status">{t.formWork.slow}</p>{/if}
      <form
        onsubmit={(event) => void saveTitle(event)}
        class="border-border flex max-w-xl flex-col gap-3 border-t pt-4 sm:flex-row sm:items-end"
      >
        <div class="min-w-0 flex-1">
          <Row id="form-title" label={t.admin.form.title}
            ><Input
              id="form-title"
              bind:value={titleText}
              oninput={() => (titleChanged = true)}
              disabled={editor.saving}
              required
              maxlength={190}
            /></Row
          >
        </div>
        <div>
          <Button type="submit" variant="outline" disabled={editor.saving || !titleChanged}
            >{t.admin.form.titleSave}</Button
          >
        </div>
      </form>
      <p class="text-muted-foreground text-sm">
        {t.admin.fields.sensitiveHint}
      </p>
      {#if fields.length === 0}
        <p class="bg-muted/60 text-muted-foreground rounded-lg p-4 text-center">
          {t.formWork.firstField}
        </p>
      {:else}
        <ul class="divide-border border-border flex flex-col divide-y border-y">
          {#each fields as f (f.id)}
            <li class="flex min-h-14 flex-wrap items-center justify-between gap-x-3 gap-y-1 py-2">
              <span class="min-w-0 break-words">
                <span class="font-medium">{f.label}</span>
                <span class="text-muted-foreground ml-2 text-sm"
                  >{t.admin.fields.kinds[f.kind as FieldKind] ?? f.kind}{f.required
                    ? ' · ' + t.admin.fields.required
                    : ''}</span
                >
              </span>
              {#if !FIELD_KINDS.includes(f.kind as FieldKind)}<p
                  class="text-muted-foreground text-sm"
                >
                  {t.formWork.unsupportedField}
                </p>{/if}
              <span class="flex flex-wrap gap-1">
                <Button
                  variant="ghost"
                  disabled={editor.saving || editing !== null || !canMove(f.id, -1)}
                  onclick={() => void move(f.id, -1)}
                  >{t.formWork.up}<span class="sr-only"> {f.label}</span></Button
                >
                <Button
                  variant="ghost"
                  disabled={editor.saving || editing !== null || !canMove(f.id, 1)}
                  onclick={() => void move(f.id, 1)}
                  >{t.formWork.down}<span class="sr-only"> {f.label}</span></Button
                >
                <Button
                  type="button"
                  variant="outline"
                  disabled={editor.saving || !FIELD_KINDS.includes(f.kind as FieldKind)}
                  onclick={() => {
                    if (!changed || confirm(t.formWork.unsaved)) open(f.id);
                  }}>{t.admin.edit}<span class="sr-only"> {f.label}</span></Button
                >
                <Button
                  type="button"
                  variant="ghost"
                  disabled={editor.saving || editing !== null}
                  onclick={() => void remove(f.id, f.name)}
                  >{t.admin.remove}<span class="sr-only"> {f.label}</span></Button
                >
              </span>
            </li>
          {/each}
        </ul>
      {/if}
      <p class="text-muted-foreground text-sm">{t.formWork.orderHint}</p>
      <Notice
        message={notice ||
          (editor.error
            ? editor.error.status === 409
              ? t.formWork.conflict
              : describeError(editor.error)
            : '')}
      />
      {#if editor.error?.status === 409}<div>
          <Button
            variant="outline"
            onclick={() => {
              if (!changed || confirm(t.formWork.unsaved)) {
                editing = null;
                changed = false;
                void editor.load();
              }
            }}>{t.formWork.reload}</Button
          >
        </div>{/if}
      {#if preview}
        <section class="bg-muted/60 space-y-4 rounded-xl p-4" aria-label={t.formWork.preview}>
          <h3 class="font-medium">{t.formWork.preview}</h3>
          <p class="text-muted-foreground text-sm">{t.formWork.previewHint}</p>
          {#each fields.filter((f) => obj(obj(formOf(editor.draft!.document).fields)[f.id]).hidden !== true) as f (f.id)}
            <Row id={`preview-${f.id}`} label={f.label + (f.required ? ' *' : '')}>
              <Input id={`preview-${f.id}`} readonly value="" tabindex={-1} />
            </Row>
          {/each}
        </section>
      {/if}

      {#if editing === null}
        <div><Button type="button" onclick={() => open('')}>{t.admin.fields.add}</Button></div>
      {:else}
        <form
          onsubmit={(e) => void submit(e)}
          oninput={() => (changed = true)}
          onchange={() => (changed = true)}
          class="border-border flex max-w-xl flex-col gap-3 rounded-xl border p-4"
        >
          <fieldset disabled={editor.saving} class="contents">
            <h3 class="font-medium">{editing === '' ? t.admin.fields.add : t.admin.edit}</h3>
            <details open={editing === ''}>
              <summary class="cursor-pointer text-sm font-medium">{t.formWork.advanced}</summary>
              <Row id="field-name" label={t.admin.fields.name} hint={t.admin.fields.nameHint}>
                <Input
                  id="field-name"
                  aria-invalid={['name', 'duplicate', 'reserved'].includes(problemFor)}
                  aria-describedby="field-problem field-name-hint"
                  bind:value={name}
                  readonly={editing !== ''}
                  required
                  maxlength={64}
                  autocomplete="off"
                  spellcheck={false}
                />
              </Row>
            </details>
            <Row id="field-label" label={t.admin.fields.label}>
              <Input
                id="field-label"
                aria-invalid={problemFor === 'label'}
                aria-describedby={problemFor === 'label' ? 'field-problem' : undefined}
                bind:value={label}
                required
                maxlength={190}
                autocomplete="off"
              />
            </Row>
            <Row id="field-kind" label={t.admin.fields.kind}>
              <Select id="field-kind" bind:value={kind}>
                {#each FIELD_KINDS as k (k)}<option value={k}>{t.admin.fields.kinds[k]}</option
                  >{/each}
              </Select>
            </Row>
            {#if kind === 'choice'}
              <Row id="field-options" label={t.admin.fields.options}>
                <Textarea
                  id="field-options"
                  aria-invalid={problemFor === 'options'}
                  aria-describedby={problemFor === 'options' ? 'field-problem' : undefined}
                  bind:value={optionsText}
                />
              </Row>
            {/if}
            <label class="flex min-h-10 items-center gap-3 text-sm">
              <input type="checkbox" bind:checked={required} class={box} />
              {t.admin.fields.required}
            </label>
            <Row id="field-visibility" label={t.formWork.visibility} hint={t.formWork.hiddenHint}>
              <Select
                id="field-visibility"
                value={hidden ? 'hidden' : 'visible'}
                onchange={(e) => {
                  hidden = e.currentTarget.value === 'hidden';
                  changed = true;
                }}
                ><option value="visible">{t.formWork.visible}</option><option value="hidden"
                  >{t.formWork.hidden}</option
                ></Select
              >
            </Row>
            <p class="text-muted-foreground text-xs">{t.formWork.viewHint}</p>
            <label class="flex min-h-10 items-center gap-3 text-sm"
              ><input type="checkbox" bind:checked={readOnly} class={box} />{t.formWork
                .readOnly}</label
            >
            <label class="flex min-h-10 items-center gap-3 text-sm"
              ><input type="checkbox" bind:checked={disabled} class={box} />{t.formWork
                .disabled}</label
            >
            <label class="flex min-h-10 items-center gap-3 text-sm"
              ><input type="checkbox" bind:checked={locked} class={box} />{t.formWork.fixed}</label
            >
            {#if locked}<Row id="field-fixed" label={t.formWork.fixedValue}
                ><Input id="field-fixed" bind:value={fixedValue} /></Row
              >{/if}
            <div id="field-problem"><Notice message={problem} /></div>
            <div class="flex gap-2">
              <Button type="submit" disabled={editor.saving}>{t.admin.save}</Button>
              <Button
                type="button"
                variant="outline"
                onclick={() => {
                  if (!changed || confirm(t.formWork.unsaved)) {
                    editing = null;
                    changed = false;
                  }
                }}>{t.admin.cancel}</Button
              >
            </div>
          </fieldset>
        </form>
      {/if}
    </DraftGate>
  </div>
</Panel>
