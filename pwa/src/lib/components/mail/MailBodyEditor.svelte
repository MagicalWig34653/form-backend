<script lang="ts">
  // Body of a mail template. Text mails: a plain field. HTML mails: three modes on the same stored body —
  // Design (MJML blocks → table HTML), Einfach (rich text in a mail-safe frame), Quelltext (the raw HTML).
  // The editable source travels in a marker comment inside the body (see source.ts), so no backend change is needed.
  import { tick } from 'svelte';
  import { t } from '$lib/i18n';
  import { confirmAction } from '$lib/confirm.svelte';
  import { Button } from '$lib/components/ui/button';
  import { Tabs } from 'bits-ui';
  import { TabsList, TabsTrigger, TabsContent } from '$lib/components/ui/tabs';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import LayoutTemplate from '@lucide/svelte/icons/layout-template';
  import Pilcrow from '@lucide/svelte/icons/pilcrow';
  import CodeXml from '@lucide/svelte/icons/code-xml';
  // Editors load on demand (own chunks), like the MJML compiler: the main bundle only carries this shell.
  import type DesignEditor from './DesignEditor.svelte';
  import type RichTextEditor from './RichTextEditor.svelte';
  import MailPreview from './MailPreview.svelte';
  import {
    MAX_BODY_BYTES,
    byteLength,
    composeBody,
    initialMode,
    readMarker,
    stripMarker,
    type BuilderMode,
  } from './source';
  import {
    designToRichText,
    docFromRichText,
    parseMjml,
    serializeMjml,
    templateDoc,
    type DesignDoc,
  } from './design';
  import { compileMjmlSync, loadMjml, mjmlReady } from './compile';
  import { sanitizeRichText, simpleFrame } from './richtext';
  import { bodyAfterSourceEdit, planSwitch } from './modes';

  interface Props {
    /** Id of the main control (the textarea in text/source mode). */
    id: string;
    value: string;
    format: 'text' | 'html';
    names: string[];
    label: string;
    error?: string | undefined;
    /** Called after every user change of the body. */
    onedit?: () => void;
  }
  let {
    id,
    value = $bindable(''),
    format,
    names,
    label,
    error,
    onedit = () => {},
  }: Props = $props();

  const b = t.admin.mail.builder;
  let mode = $state<BuilderMode>('source');
  let doc = $state<DesignDoc | null>(null);
  let rich = $state('');
  let loading = $state(false);
  let loadFailed = $state(false);
  let unreadable = $state(false);
  let compileErrors = $state<string[]>([]);
  let compileFailed = $state(false);
  let DesignView = $state<typeof DesignEditor | null>(null);
  let RichView = $state<typeof RichTextEditor | null>(null);
  let designEditor = $state<DesignEditor>();
  let richEditor = $state<RichTextEditor>();
  let lastEmitted: string | null = null;
  let seq = 0;

  const greeting = { greeting: b.blocks.greeting };
  const errorId = $derived(error ? `${id}-error` : undefined);
  const bytes = $derived(byteLength(value));
  const marker = $derived(readMarker(value));

  /** (Re)initialises from a body that did not come from this editor (load, reload after save, discard). */
  function init(body: string): void {
    lastEmitted = body;
    compileErrors = [];
    compileFailed = false;
    unreadable = false;
    loadFailed = false;
    const m = readMarker(body);
    doc = null;
    rich = '';
    let start = initialMode(body);
    if (m?.kind === 'design') {
      doc = parseMjml(m.source);
      if (!doc) {
        unreadable = true;
        start = 'source';
      }
    } else if (m?.kind === 'simple') rich = m.source;
    mode = start;
    if (mode !== 'source') void ensureEditor(mode);
  }

  $effect(() => {
    if (value !== lastEmitted) init(value);
  });

  function emit(body: string): void {
    lastEmitted = body;
    value = body;
    onedit();
  }

  async function ensureEditor(kind: 'design' | 'simple'): Promise<boolean> {
    if (kind === 'design' ? mjmlReady() && DesignView : RichView) return true;
    loading = true;
    loadFailed = false;
    try {
      if (kind === 'design') {
        const [view] = await Promise.all([import('./DesignEditor.svelte'), loadMjml()]);
        DesignView = view.default;
      } else RichView = (await import('./RichTextEditor.svelte')).default;
      return true;
    } catch {
      loadFailed = true;
      return false;
    } finally {
      loading = false;
    }
  }

  /** Compiles the open design and writes marker + HTML. Synchronous once the compiler is loaded. */
  async function emitDesign(): Promise<void> {
    const n = ++seq;
    if (!mjmlReady() && !(await ensureEditor('design'))) return;
    if (n !== seq || !doc) return;
    const source = serializeMjml(doc);
    try {
      const r = compileMjmlSync(source);
      compileErrors = r.errors;
      compileFailed = false;
      emit(composeBody({ kind: 'design', source, handEdited: false }, r.html));
    } catch {
      compileFailed = true;
    }
  }

  function emitSimple(html: string): void {
    rich = html;
    emit(composeBody({ kind: 'simple', source: html, handEdited: false }, simpleFrame(html)));
  }

  async function requestMode(target: BuilderMode): Promise<void> {
    if (target === mode) return;
    const markerNow = readMarker(value);
    const designForRich =
      mode === 'design' ? doc : markerNow?.kind === 'design' ? parseMjml(markerNow.source) : null;
    const plan = planSwitch(
      mode,
      target,
      value,
      designForRich ? designToRichText(designForRich) : '',
    );
    if (plan.question) {
      const q = b.questions[plan.question];
      const ok = await confirmAction({
        title: q.title,
        description: q.description,
        confirmLabel: q.confirm,
        destructive: true,
      });
      if (!ok) return;
    }
    if (target === 'design') {
      if (!(await ensureEditor('design'))) return;
      const seed = plan.seed;
      let next: DesignDoc | null = null;
      if (seed.kind === 'design-source') next = parseMjml(seed.value);
      else if (seed.kind === 'design-from-rich')
        next = seed.value ? docFromRichText(seed.value, greeting) : templateDoc(greeting);
      if (!next) next = templateDoc(greeting);
      unreadable = false;
      doc = next;
      mode = 'design';
      if (plan.regenerate) await emitDesign();
      return;
    }
    if (target === 'simple') {
      if (!(await ensureEditor('simple'))) return;
      const html = sanitizeRichText(plan.seed.value);
      rich = html;
      mode = 'simple';
      if (plan.regenerate) emitSimple(html);
      return;
    }
    mode = 'source';
  }

  const shownSource = $derived(format === 'html' ? stripMarker(value) : value);

  function onSourceInput(event: Event): void {
    const text = (event.currentTarget as HTMLTextAreaElement).value;
    emit(format === 'html' ? bodyAfterSourceEdit(value, text) : text);
  }

  /** Inserts `#=[name]=#` at the caret of the active editor. */
  async function insert(name: string): Promise<void> {
    const token = `#=[${name}]=#`;
    if (format === 'html' && mode === 'design' && designEditor) {
      designEditor.insertPlaceholder(token);
      return;
    }
    if (format === 'html' && mode === 'simple' && richEditor) {
      richEditor.insertText(token);
      return;
    }
    const el = document.getElementById(id) as HTMLTextAreaElement | null;
    const text = shownSource;
    const start = el?.selectionStart ?? text.length;
    const end = el?.selectionEnd ?? start;
    const next = text.slice(0, start) + token + text.slice(end);
    emit(format === 'html' ? bodyAfterSourceEdit(value, next) : next);
    await tick();
    el?.focus();
    el?.setSelectionRange(start + token.length, start + token.length);
  }

  const modes: { value: BuilderMode; label: string; icon: typeof CodeXml }[] = [
    { value: 'design', label: b.design, icon: LayoutTemplate },
    { value: 'simple', label: b.simple, icon: Pilcrow },
    { value: 'source', label: b.source, icon: CodeXml },
  ];
</script>

{#snippet chips()}
  <div class="flex flex-col gap-1.5" role="group" aria-labelledby={`${id}-chips-label`}>
    <span id={`${id}-chips-label`} class="text-sm leading-5 font-medium">{t.formWork.insert}</span>
    <div class="flex flex-wrap gap-1.5">
      {#each names as name (name)}
        <Button
          type="button"
          variant="outline"
          size="sm"
          onmousedown={(e: MouseEvent) => e.preventDefault()}
          onclick={() => void insert(name)}>{name}</Button
        >
      {:else}
        <span class="text-muted-foreground text-sm">{t.admin.mail.none}</span>
      {/each}
    </div>
    <p class="text-muted-foreground m-0 text-xs">{t.admin.mail.bodyHint}</p>
  </div>
{/snippet}

{#snippet source(rows: string)}
  <Textarea
    {id}
    value={shownSource}
    oninput={onSourceInput}
    aria-labelledby={`${id}-label`}
    aria-invalid={error ? 'true' : undefined}
    aria-describedby={[errorId, `${id}-size`].filter(Boolean).join(' ')}
    spellcheck={format === 'html' ? 'false' : undefined}
    class={rows}
  />
{/snippet}

<div class="flex min-w-0 flex-col gap-3" data-testid={`${id}-editor`}>
  <span id={`${id}-label`} class="text-sm leading-5 font-medium">{label}</span>
  {#if format === 'text'}
    {@render chips()}
    {@render source('min-h-40')}
  {:else}
    <Tabs.Root
      bind:value={() => mode, (v) => void requestMode(v as BuilderMode)}
      activationMode="manual"
      class="flex flex-col gap-3"
    >
      <TabsList aria-label={b.modes} class="w-full sm:w-fit">
        {#each modes as m (m.value)}
          {@const Icon = m.icon}
          <TabsTrigger value={m.value} class="gap-1.5 px-2 sm:px-3"
            ><Icon size={16} aria-hidden="true" class="hidden sm:block" />{m.label}</TabsTrigger
          >
        {/each}
      </TabsList>
      {#if loading}<p role="status" class="text-muted-foreground m-0 text-sm">{b.loading}</p>{/if}
      {#if loadFailed}<p role="alert" class="text-destructive m-0 text-sm">{b.loadFailed}</p>{/if}
      {#if unreadable}<p role="alert" class="text-destructive m-0 text-sm">{b.unreadable}</p>{/if}

      <TabsContent value="design">
        {#if mode === 'design' && doc && DesignView}
          <DesignView
            bind:this={designEditor}
            bind:doc
            {id}
            body={value}
            {chips}
            errors={compileErrors}
            failed={compileFailed}
            onchange={() => void emitDesign()}
          />
        {/if}
      </TabsContent>
      <TabsContent value="simple" class="flex flex-col gap-3">
        {#if mode === 'simple'}
          {@render chips()}
          {#if RichView}
            <RichView
              bind:this={richEditor}
              id={`${id}-rich`}
              html={rich}
              label={b.simpleLabel}
              describedby={[errorId, `${id}-size`].filter(Boolean).join(' ')}
              onchange={emitSimple}
            />
          {/if}
          <MailPreview body={value} {id} />
        {/if}
      </TabsContent>
      <TabsContent value="source" class="flex flex-col gap-3">
        {#if mode === 'source'}
          {@render chips()}
          {#if marker}<p class="text-muted-foreground m-0 text-xs">{b.sourceKept}</p>{/if}
          {@render source('min-h-60 font-mono text-xs')}
          <MailPreview body={value} {id} />
        {/if}
      </TabsContent>
    </Tabs.Root>
  {/if}
  <p
    id={`${id}-size`}
    class="m-0 text-xs {bytes > MAX_BODY_BYTES
      ? 'text-red-700 dark:text-destructive'
      : 'text-muted-foreground'}"
  >
    {b.size.replace('{kb}', (bytes / 1000).toLocaleString('de-DE', { maximumFractionDigits: 1 }))}
    {#if bytes > MAX_BODY_BYTES}— {b.tooLarge}{/if}
  </p>
  {#if error}<p id={`${id}-error`} role="alert" class="text-red-700 dark:text-destructive text-sm">
      {error}
    </p>{/if}
</div>
