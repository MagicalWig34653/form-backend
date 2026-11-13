<script lang="ts">
  // Block editor for MJML mails: add blocks by click or drag, reorder by drag, buttons or Alt+Arrow, edit the selected
  // block's properties. The canvas is the compiled mail in the sandboxed preview frame (mail colours, app frame).
  import { onMount, tick } from 'svelte';
  import type { Component, Snippet } from 'svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Select from '$lib/components/admin/Select.svelte';
  import Textarea from '$lib/components/admin/Textarea.svelte';
  import Type from '@lucide/svelte/icons/type';
  import MousePointerClick from '@lucide/svelte/icons/mouse-pointer-click';
  import ImageIcon from '@lucide/svelte/icons/image';
  import SeparatorHorizontal from '@lucide/svelte/icons/separator-horizontal';
  import MoveVertical from '@lucide/svelte/icons/move-vertical';
  import CodeXml from '@lucide/svelte/icons/code-xml';
  import GripVertical from '@lucide/svelte/icons/grip-vertical';
  import ArrowUp from '@lucide/svelte/icons/arrow-up';
  import ArrowDown from '@lucide/svelte/icons/arrow-down';
  import Trash from '@lucide/svelte/icons/trash-2';
  import Maximize from '@lucide/svelte/icons/maximize-2';
  import Minimize from '@lucide/svelte/icons/minimize-2';
  import Info from '@lucide/svelte/icons/info';
  import RichTextEditor from './RichTextEditor.svelte';
  import MailPreview from './MailPreview.svelte';
  import {
    blockProblems,
    moveBlock,
    newBlock,
    type BlockType,
    type DesignBlock,
    type DesignDoc,
    type SimpleBlock,
  } from './design';
  import { escapeText, textOf } from './richtext';

  interface Props {
    id: string;
    doc: DesignDoc;
    body: string;
    onchange: () => void;
    chips: Snippet;
    errors?: string[];
    failed?: boolean;
  }
  let {
    id,
    doc = $bindable(),
    body,
    onchange,
    chips,
    errors = [],
    failed = false,
  }: Props = $props();

  const b = t.admin.mail.builder;
  const L = b.blocks;
  const P = b.props;
  type Kind = BlockType | 'raw';
  const palette: { type: Kind; icon: Component<{ size?: number; 'aria-hidden'?: 'true' }> }[] = [
    { type: 'text', icon: Type },
    { type: 'button', icon: MousePointerClick },
    { type: 'image', icon: ImageIcon },
    { type: 'divider', icon: SeparatorHorizontal },
    { type: 'spacer', icon: MoveVertical },
    { type: 'raw', icon: CodeXml },
  ];
  const DRAG_NEW = 'application/x-mail-block';
  const DRAG_MOVE = 'application/x-mail-move';

  let selected = $state<string | null>(doc.blocks[0]?.id ?? null);
  let announce = $state('');
  let full = $state(false);
  let fallback = $state(false);
  let dropIndex = $state<number | null>(null);
  let wrap = $state<HTMLDivElement>();
  let rich = $state<RichTextEditor>();

  const current = $derived(doc.blocks.find((x) => x.id === selected) ?? null);
  const index = $derived(current ? doc.blocks.indexOf(current) : -1);

  const typeLabel = (type: Kind): string => L.types[type];
  function summary(block: DesignBlock): string {
    if (block.type === 'raw') return (/<([a-z-]+)/i.exec(block.mjml)?.[1] ?? '').slice(0, 40);
    if (block.type === 'text' || block.type === 'button')
      return textOf(block.content.replace(/<br\s*\/?>/gi, ' '))
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 40);
    if (block.type === 'image') return block.attrs.alt || block.attrs.src || '';
    if (block.type === 'spacer') return block.attrs.height ?? '';
    return '';
  }
  const nameOf = (block: DesignBlock): string => {
    const s = summary(block);
    return s ? `${typeLabel(block.type)}: ${s}` : typeLabel(block.type);
  };
  const fill = (text: string, values: Record<string, string | number>): string =>
    Object.entries(values).reduce((s, [k, v]) => s.replace(`{${k}}`, String(v)), text);

  function add(type: Kind, at?: number): void {
    const block = newBlock(type, { text: L.newText, button: L.newButton });
    const position = at ?? (index >= 0 ? index + 1 : doc.blocks.length);
    doc.blocks = [...doc.blocks.slice(0, position), block, ...doc.blocks.slice(position)];
    selected = block.id;
    announce = fill(L.added, {
      label: typeLabel(type),
      n: position + 1,
      total: doc.blocks.length,
    });
    onchange();
  }

  function move(from: number, to: number, focus = true): void {
    if (to < 0 || to >= doc.blocks.length || from === to) return;
    const block = doc.blocks[from]!;
    doc.blocks = moveBlock(doc.blocks, from, to);
    announce = fill(L.moved, { label: nameOf(block), n: to + 1, total: doc.blocks.length });
    onchange();
    if (focus)
      void tick().then(() =>
        document.querySelector<HTMLElement>(`[data-select="${id}-${block.id}"]`)?.focus(),
      );
  }

  function remove(at: number): void {
    const block = doc.blocks[at];
    if (!block) return;
    doc.blocks = doc.blocks.filter((_, i) => i !== at);
    selected = doc.blocks[Math.min(at, doc.blocks.length - 1)]?.id ?? null;
    announce = fill(L.removed, { label: nameOf(block) });
    onchange();
    void tick().then(() => {
      const target = selected
        ? document.querySelector<HTMLElement>(`[data-select="${id}-${selected}"]`)
        : document.getElementById(`${id}-add-text`);
      target?.focus();
    });
  }

  function setAttr(block: SimpleBlock, key: string, value: string): void {
    if (value === '') delete block.attrs[key];
    else block.attrs[key] = value;
    onchange();
  }

  /** Inserts a placeholder: at the caret of the selected text block or button label, else as a new text block. */
  export function insertPlaceholder(token: string): void {
    if (current?.type === 'text' && rich) {
      rich.insertText(token);
      return;
    }
    const labelInput = document.getElementById(`${id}-p-label`) as HTMLInputElement | null;
    if (current?.type === 'button' && labelInput) {
      const el = labelInput;
      const text = textOf(current.content);
      const start = el.selectionStart ?? text.length;
      const end = el.selectionEnd ?? start;
      const next = text.slice(0, start) + token + text.slice(end);
      current.content = escapeText(next);
      onchange();
      void tick().then(() => {
        el.focus();
        el.setSelectionRange(start + token.length, start + token.length);
      });
      return;
    }
    add('text');
    const block = doc.blocks.find((x) => x.id === selected);
    if (block && block.type === 'text') {
      block.content = `<p>${escapeText(token)}</p>`;
      onchange();
    }
  }

  function onListKey(event: KeyboardEvent, at: number): void {
    if (!event.altKey || (event.key !== 'ArrowUp' && event.key !== 'ArrowDown')) return;
    event.preventDefault();
    move(at, event.key === 'ArrowUp' ? at - 1 : at + 1);
  }

  function dragOver(event: DragEvent, at: number): void {
    const types = event.dataTransfer?.types ?? [];
    if (!types.includes(DRAG_NEW) && !types.includes(DRAG_MOVE)) return;
    event.preventDefault();
    const box = (event.currentTarget as HTMLElement).getBoundingClientRect();
    dropIndex = event.clientY > box.top + box.height / 2 ? at + 1 : at;
  }
  function drop(event: DragEvent): void {
    event.preventDefault();
    const target = dropIndex ?? doc.blocks.length;
    dropIndex = null;
    const kind = event.dataTransfer?.getData(DRAG_NEW);
    if (kind) {
      add(kind as Kind, target);
      return;
    }
    const moving = event.dataTransfer?.getData(DRAG_MOVE);
    const from = doc.blocks.findIndex((x) => x.id === moving);
    if (from >= 0) move(from, from < target ? target - 1 : target, false);
  }

  const hex = (value: string | undefined): string => {
    const v = (value ?? '').trim();
    if (/^#[0-9a-f]{6}$/i.test(v)) return v.toLowerCase();
    const short = /^#([0-9a-f])([0-9a-f])([0-9a-f])$/i.exec(v);
    return short
      ? `#${short[1]}${short[1]}${short[2]}${short[2]}${short[3]}${short[3]}`.toLowerCase()
      : '#000000';
  };
  const px = (value: string | undefined): string => /^(\d+)px$/.exec(value ?? '')?.[1] ?? '';

  async function toggleFull(): Promise<void> {
    if (full) {
      if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
      fallback = false;
      full = false;
      return;
    }
    if (wrap && document.fullscreenEnabled && wrap.requestFullscreen) {
      try {
        await wrap.requestFullscreen();
        full = true;
        return;
      } catch {
        /* fall back to the fixed overlay */
      }
    }
    fallback = true;
    full = true;
  }

  onMount(() => {
    const onChange = (): void => {
      if (!document.fullscreenElement && !fallback) full = false;
    };
    document.addEventListener('fullscreenchange', onChange);
    return () => {
      document.removeEventListener('fullscreenchange', onChange);
      if (document.fullscreenElement === wrap) void document.exitFullscreen().catch(() => {});
    };
  });
</script>

{#snippet color(block: SimpleBlock, key: string, label: string)}
  <div class="flex items-center gap-3">
    <input
      id={`${id}-p-${key}`}
      type="color"
      value={hex(block.attrs[key])}
      oninput={(e) => setAttr(block, key, (e.currentTarget as HTMLInputElement).value)}
      class="border-input size-10 shrink-0 cursor-pointer rounded-md border bg-transparent p-1"
    />
    <label for={`${id}-p-${key}`} class="text-sm font-medium">{label}</label>
  </div>
{/snippet}

{#snippet align(block: SimpleBlock)}
  <div class="flex flex-col gap-1.5">
    <label for={`${id}-p-align`} class="text-sm font-medium">{P.align}</label>
    <Select
      id={`${id}-p-align`}
      value={block.attrs.align ?? 'left'}
      onchange={(e) => setAttr(block, 'align', (e.currentTarget as HTMLSelectElement).value)}
    >
      <option value="left">{P.alignLeft}</option>
      <option value="center">{P.alignCenter}</option>
      <option value="right">{P.alignRight}</option>
    </Select>
  </div>
{/snippet}

<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
<div
  bind:this={wrap}
  role="region"
  aria-label={b.design}
  class="flex min-w-0 flex-col gap-3 {full
    ? 'bg-background text-foreground overflow-auto p-4'
    : ''} {fallback ? 'fixed inset-0 z-40' : ''}"
  onkeydown={(e) => {
    if (fallback && e.key === 'Escape') {
      e.preventDefault();
      void toggleFull();
    }
  }}
>
  <p
    class="text-muted-foreground m-0 flex items-start gap-2 text-sm md:hidden"
    data-testid={`${id}-mobile-hint`}
  >
    <Info size={16} aria-hidden="true" class="mt-0.5 shrink-0" />{b.mobileHint}
  </p>

  <div class="flex flex-wrap items-start justify-between gap-2">
    <div class="flex min-w-0 flex-col gap-1.5" role="group" aria-labelledby={`${id}-add-label`}>
      <span id={`${id}-add-label`} class="text-sm font-medium">{L.add}</span>
      <div class="flex flex-wrap gap-1.5">
        {#each palette as item (item.type)}
          {@const Icon = item.icon}
          <Button
            id={`${id}-add-${item.type}`}
            type="button"
            variant="outline"
            size="sm"
            draggable="true"
            ondragstart={(e: DragEvent) => {
              e.dataTransfer?.setData(DRAG_NEW, item.type);
              if (e.dataTransfer) e.dataTransfer.effectAllowed = 'copy';
            }}
            onclick={() => add(item.type)}
            ><Icon size={16} aria-hidden="true" />{typeLabel(item.type)}</Button
          >
        {/each}
      </div>
      <p class="text-muted-foreground m-0 text-xs">{L.addHint}</p>
    </div>
    <Button type="button" variant="outline" size="sm" onclick={() => void toggleFull()}>
      {#if full}<Minimize size={16} aria-hidden="true" />{b.exitFullscreen}{:else}<Maximize
          size={16}
          aria-hidden="true"
        />{b.fullscreen}{/if}
    </Button>
  </div>

  {@render chips()}

  {#if failed}<p role="alert" class="text-destructive m-0 text-sm">{b.compileFailed}</p>{/if}
  {#if errors.length}
    <details class="text-sm">
      <summary class="cursor-pointer text-amber-700 dark:text-amber-400"
        >{fill(b.compileErrors, { n: errors.length })}</summary
      >
      <ul class="text-muted-foreground mt-1 list-disc pl-5 text-xs">
        {#each errors as message, i (i)}<li>{message}</li>{/each}
      </ul>
    </details>
  {/if}

  <div
    class="grid min-w-0 gap-4 {full
      ? 'lg:grid-cols-[minmax(200px,260px)_minmax(0,1fr)_minmax(260px,340px)]'
      : ''}"
  >
    <section class="order-1 flex min-w-0 flex-col gap-2" aria-labelledby={`${id}-list-label`}>
      <h4 id={`${id}-list-label`} class="m-0 text-sm font-semibold">{L.list}</h4>
      <p id={`${id}-list-hint`} class="text-muted-foreground m-0 text-xs">{L.listHint}</p>
      <ol
        class="border-border m-0 flex min-h-16 list-none flex-col gap-1 rounded-md border p-1"
        ondragover={(e) => {
          if (doc.blocks.length === 0) dragOver(e, 0);
        }}
        ondrop={drop}
        ondragleave={(e) => {
          if (!(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node)) dropIndex = null;
        }}
      >
        {#each doc.blocks as block, i (block.id)}
          <li
            class="relative flex min-w-0 items-center gap-1 rounded-md {selected === block.id
              ? 'bg-accent'
              : ''}"
            ondragover={(e) => dragOver(e, i)}
          >
            {#if dropIndex === i}<span
                class="bg-primary absolute -top-0.5 right-1 left-1 h-0.5 rounded"
                aria-hidden="true"
              ></span>{/if}
            {#if dropIndex === i + 1 && i === doc.blocks.length - 1}<span
                class="bg-primary absolute right-1 -bottom-0.5 left-1 h-0.5 rounded"
                aria-hidden="true"
              ></span>{/if}
            <span
              draggable="true"
              aria-hidden="true"
              title={fill(L.drag, { label: nameOf(block) })}
              class="text-muted-foreground flex size-8 shrink-0 cursor-grab items-center justify-center"
              ondragstart={(e) => {
                e.dataTransfer?.setData(DRAG_MOVE, block.id);
                if (e.dataTransfer) e.dataTransfer.effectAllowed = 'move';
              }}><GripVertical size={16} /></span
            >
            <button
              type="button"
              data-select={`${id}-${block.id}`}
              aria-current={selected === block.id ? 'true' : undefined}
              aria-describedby={`${id}-list-hint`}
              class="focus-visible:ring-ring hover:bg-accent/60 min-h-11 min-w-0 flex-1 truncate rounded-md px-2 text-left text-sm focus-visible:ring-2 focus-visible:outline-none sm:min-h-9"
              onclick={() => (selected = block.id)}
              onkeydown={(e) => onListKey(e, i)}
              ><span class="font-medium">{typeLabel(block.type)}</span>{#if summary(block)}<span
                  class="text-muted-foreground">&nbsp;· {summary(block)}</span
                >{/if}</button
            >
            <span class="flex shrink-0">
              <button
                type="button"
                class="hover:bg-secondary focus-visible:ring-ring inline-flex size-11 items-center justify-center rounded-md focus-visible:ring-2 focus-visible:outline-none disabled:opacity-40 sm:size-8"
                aria-label={fill(L.up, { label: nameOf(block) })}
                disabled={i === 0}
                onclick={() => move(i, i - 1)}><ArrowUp size={16} aria-hidden="true" /></button
              >
              <button
                type="button"
                class="hover:bg-secondary focus-visible:ring-ring inline-flex size-11 items-center justify-center rounded-md focus-visible:ring-2 focus-visible:outline-none disabled:opacity-40 sm:size-8"
                aria-label={fill(L.down, { label: nameOf(block) })}
                disabled={i === doc.blocks.length - 1}
                onclick={() => move(i, i + 1)}><ArrowDown size={16} aria-hidden="true" /></button
              >
              <button
                type="button"
                class="hover:bg-secondary focus-visible:ring-ring inline-flex size-11 items-center justify-center rounded-md text-red-700 focus-visible:ring-2 focus-visible:outline-none sm:size-8 dark:text-red-400"
                aria-label={fill(L.remove, { label: nameOf(block) })}
                onclick={() => remove(i)}><Trash size={16} aria-hidden="true" /></button
              >
            </span>
          </li>
        {:else}
          <li class="text-muted-foreground p-3 text-sm">{L.empty}</li>
        {/each}
      </ol>
      <p class="sr-only" role="status">{announce}</p>

      <details class="border-border rounded-md border p-2">
        <summary class="min-h-8 cursor-pointer text-sm font-medium">{P.frame}</summary>
        <div class="mt-2 flex flex-col gap-2">
          {#each [['bodyAttrs', P.bodyColor], ['sectionAttrs', P.cardColor]] as const as [part, label] (part)}
            <div class="flex items-center gap-3">
              <input
                id={`${id}-frame-${part}`}
                type="color"
                value={hex(doc[part]['background-color'])}
                oninput={(e) => {
                  doc[part]['background-color'] = (e.currentTarget as HTMLInputElement).value;
                  onchange();
                }}
                class="border-input size-10 shrink-0 cursor-pointer rounded-md border bg-transparent p-1"
              />
              <label for={`${id}-frame-${part}`} class="text-sm font-medium">{label}</label>
            </div>
          {/each}
        </div>
      </details>
    </section>

    <section
      class="flex min-w-0 flex-col gap-3 {full ? 'order-2 lg:order-3' : 'order-2'}"
      aria-labelledby={`${id}-props-label`}
    >
      <h4 id={`${id}-props-label`} class="m-0 text-sm font-semibold">
        {P.title}{#if current}: {typeLabel(current.type)}{/if}
      </h4>
      {#if !current}
        <p class="text-muted-foreground m-0 text-sm">{P.none}</p>
      {:else if current.type === 'text'}
        {#key current.id}
          <RichTextEditor
            bind:this={rich}
            id={`${id}-p-text`}
            label={P.text}
            html={current.content}
            onchange={(html) => {
              if (current.type === 'text') current.content = html;
              onchange();
            }}
          />
        {/key}
        {@render color(current, 'color', P.textColor)}
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-size`} class="text-sm font-medium">{P.fontSize}</label>
          <Select
            id={`${id}-p-size`}
            value={current.attrs['font-size'] ?? '15px'}
            onchange={(e) =>
              current.type === 'text' &&
              setAttr(current, 'font-size', (e.currentTarget as HTMLSelectElement).value)}
          >
            {#each ['13px', '14px', '15px', '16px', '18px', '20px', '24px', '28px'] as size (size)}
              <option value={size}>{size}</option>
            {/each}
          </Select>
        </div>
        {@render align(current)}
      {:else if current.type === 'button'}
        {@const problems = blockProblems(current)}
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-label`} class="text-sm font-medium">{P.label}</label>
          <Input
            id={`${id}-p-label`}
            value={textOf(current.content)}
            oninput={(e) => {
              if (current.type !== 'button') return;
              current.content = escapeText((e.currentTarget as HTMLInputElement).value);
              onchange();
            }}
            autocomplete="off"
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-href`} class="text-sm font-medium">{P.href}</label>
          <Input
            id={`${id}-p-href`}
            value={current.attrs.href ?? ''}
            aria-invalid={problems.href ? 'true' : undefined}
            aria-describedby={problems.href ? `${id}-p-href-error` : undefined}
            oninput={(e) =>
              current.type === 'button' &&
              setAttr(current, 'href', (e.currentTarget as HTMLInputElement).value.trim())}
            autocomplete="off"
            inputmode="url"
          />
          {#if problems.href}<p id={`${id}-p-href-error`} class="text-destructive m-0 text-sm">
              {P.hrefInvalid}
            </p>{/if}
        </div>
        {@render color(current, 'background-color', P.background)}
        {@render color(current, 'color', P.textColor)}
        {@render align(current)}
      {:else if current.type === 'image'}
        {@const problems = blockProblems(current)}
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-src`} class="text-sm font-medium">{P.src}</label>
          <Input
            id={`${id}-p-src`}
            value={current.attrs.src ?? ''}
            aria-invalid={problems.src ? 'true' : undefined}
            aria-describedby={problems.src ? `${id}-p-src-error` : undefined}
            oninput={(e) =>
              current.type === 'image' &&
              setAttr(current, 'src', (e.currentTarget as HTMLInputElement).value.trim())}
            autocomplete="off"
            inputmode="url"
          />
          {#if problems.src}<p id={`${id}-p-src-error`} class="text-destructive m-0 text-sm">
              {P.srcInvalid}
            </p>{/if}
        </div>
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-alt`} class="text-sm font-medium">{P.alt}</label>
          <Input
            id={`${id}-p-alt`}
            value={current.attrs.alt ?? ''}
            oninput={(e) =>
              current.type === 'image' &&
              setAttr(current, 'alt', (e.currentTarget as HTMLInputElement).value)}
            autocomplete="off"
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-width`} class="text-sm font-medium">{P.width}</label>
          <Input
            id={`${id}-p-width`}
            type="number"
            min="1"
            max="600"
            value={px(current.attrs.width)}
            oninput={(e) => {
              if (current.type !== 'image') return;
              const v = (e.currentTarget as HTMLInputElement).value;
              setAttr(current, 'width', /^\d+$/.test(v) ? `${v}px` : '');
            }}
          />
        </div>
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-imghref`} class="text-sm font-medium">{P.hrefOptional}</label>
          <Input
            id={`${id}-p-imghref`}
            value={current.attrs.href ?? ''}
            aria-invalid={problems.href ? 'true' : undefined}
            aria-describedby={problems.href ? `${id}-p-imghref-error` : undefined}
            oninput={(e) =>
              current.type === 'image' &&
              setAttr(current, 'href', (e.currentTarget as HTMLInputElement).value.trim())}
            autocomplete="off"
            inputmode="url"
          />
          {#if problems.href}<p id={`${id}-p-imghref-error`} class="text-destructive m-0 text-sm">
              {P.hrefInvalid}
            </p>{/if}
        </div>
        {@render align(current)}
      {:else if current.type === 'divider'}
        {@render color(current, 'border-color', P.dividerColor)}
      {:else if current.type === 'spacer'}
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-height`} class="text-sm font-medium">{P.height}</label>
          <Input
            id={`${id}-p-height`}
            type="number"
            min="1"
            max="200"
            value={px(current.attrs.height)}
            oninput={(e) => {
              if (current.type !== 'spacer') return;
              const v = (e.currentTarget as HTMLInputElement).value;
              setAttr(current, 'height', /^\d+$/.test(v) ? `${v}px` : '');
            }}
          />
        </div>
      {:else if current.type === 'raw'}
        <div class="flex flex-col gap-1.5">
          <label for={`${id}-p-raw`} class="text-sm font-medium">{P.raw}</label>
          <Textarea
            id={`${id}-p-raw`}
            value={current.mjml}
            spellcheck="false"
            class="min-h-40 font-mono text-xs"
            aria-describedby={`${id}-p-raw-hint`}
            oninput={(e) => {
              if (current.type !== 'raw') return;
              current.mjml = (e.currentTarget as HTMLTextAreaElement).value;
              onchange();
            }}
          />
          <p id={`${id}-p-raw-hint`} class="text-muted-foreground m-0 text-xs">{P.rawHint}</p>
        </div>
      {/if}
    </section>

    <MailPreview
      {body}
      {id}
      class={full ? 'order-3 lg:order-2' : 'order-3'}
      frameClass={full ? 'h-[480px] lg:h-[calc(100dvh-14rem)]' : 'h-[480px]'}
    />
  </div>
</div>
