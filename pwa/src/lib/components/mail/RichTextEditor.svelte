<script lang="ts">
  // Small rich-text editor on contenteditable. Content enters only through the whitelist sanitizer (as DOM nodes,
  // never as raw markup) and leaves only through it, so the stored HTML stays mail-safe.
  import { onMount } from 'svelte';
  import type { Component } from 'svelte';
  import { t } from '$lib/i18n';
  import { Button } from '$lib/components/ui/button';
  import { Input } from '$lib/components/ui/input';
  import Bold from '@lucide/svelte/icons/bold';
  import Italic from '@lucide/svelte/icons/italic';
  import Underline from '@lucide/svelte/icons/underline';
  import Heading2 from '@lucide/svelte/icons/heading-2';
  import List from '@lucide/svelte/icons/list';
  import ListOrdered from '@lucide/svelte/icons/list-ordered';
  import Link from '@lucide/svelte/icons/link';
  import Unlink from '@lucide/svelte/icons/unlink';
  import RemoveFormatting from '@lucide/svelte/icons/remove-formatting';
  import {
    escapeAttr,
    escapeText,
    isSafeLink,
    sanitizedFragment,
    serializeClean,
  } from './richtext';

  interface Props {
    id: string;
    html: string;
    label: string;
    onchange: (html: string) => void;
    describedby?: string | undefined;
    class?: string;
  }
  let { id, html, label, onchange, describedby, class: className = '' }: Props = $props();

  const r = t.admin.mail.builder.rich;
  let root = $state<HTMLDivElement>();
  let saved: Range | null = null;
  let fmt = $state({
    bold: false,
    italic: false,
    underline: false,
    heading: false,
    bullet: false,
    ordered: false,
  });
  let linkOpen = $state(false);
  let linkUrl = $state('');
  let linkError = $state(false);

  onMount(() => {
    // The editable area is owned by the browser's editing engine, not by Svelte (it renders no children here);
    // initial content goes in once, as sanitized nodes.
    // eslint-disable-next-line svelte/no-dom-manipulating
    root?.replaceChildren(sanitizedFragment(html));
    const onSelection = (): void => {
      const s = document.getSelection();
      if (root && s && s.rangeCount > 0 && root.contains(s.anchorNode)) {
        saved = s.getRangeAt(0).cloneRange();
        refresh();
      }
    };
    document.addEventListener('selectionchange', onSelection);
    return () => document.removeEventListener('selectionchange', onSelection);
  });

  function query(command: string): boolean {
    try {
      return document.queryCommandState(command);
    } catch {
      return false;
    }
  }
  function refresh(): void {
    let block: string;
    try {
      block = String(document.queryCommandValue('formatBlock')).toLowerCase();
    } catch {
      block = '';
    }
    fmt = {
      bold: query('bold'),
      italic: query('italic'),
      underline: query('underline'),
      heading: block === 'h2',
      bullet: query('insertUnorderedList'),
      ordered: query('insertOrderedList'),
    };
  }

  /** Focus the editor and put the caret back where it was (or at the end). */
  function restore(): void {
    if (!root) return;
    root.focus();
    const s = document.getSelection();
    if (!s) return;
    if (saved && root.contains(saved.startContainer)) {
      s.removeAllRanges();
      s.addRange(saved);
    } else {
      const range = document.createRange();
      range.selectNodeContents(root);
      range.collapse(false);
      s.removeAllRanges();
      s.addRange(range);
    }
  }

  function emit(): void {
    if (root) onchange(serializeClean(root));
  }

  function exec(command: string, value?: string): void {
    restore();
    document.execCommand('defaultParagraphSeparator', false, 'p');
    document.execCommand('styleWithCSS', false, 'false');
    document.execCommand(command, false, value);
    emit();
    refresh();
  }

  /** Inserts plain text (a placeholder) at the caret or over the selection. */
  export function insertText(text: string): void {
    exec('insertText', text);
  }

  function toggleHeading(): void {
    exec('formatBlock', fmt.heading ? 'p' : 'h2');
  }
  function clear(): void {
    exec('removeFormat');
    exec('unlink');
    exec('formatBlock', 'p');
  }
  function openLink(): void {
    linkUrl = 'https://';
    linkError = false;
    linkOpen = true;
  }
  function applyLink(event: SubmitEvent | MouseEvent): void {
    event.preventDefault();
    const url = linkUrl.trim();
    if (!isSafeLink(url)) {
      linkError = true;
      return;
    }
    linkOpen = false;
    restore();
    const s = document.getSelection();
    if (s && s.isCollapsed)
      exec('insertHTML', `<a href="${escapeAttr(url)}">${escapeText(url)}</a>`);
    else exec('createLink', url);
  }

  function onpaste(event: ClipboardEvent): void {
    event.preventDefault();
    const text = event.clipboardData?.getData('text/plain') ?? '';
    if (text) exec('insertText', text);
  }

  const tools: {
    key: keyof typeof fmt | 'link' | 'unlink' | 'clear';
    label: string;
    icon: Component<{ size?: number; 'aria-hidden'?: 'true' }>;
    run: () => void;
  }[] = [
    { key: 'bold', label: r.bold, icon: Bold, run: () => exec('bold') },
    { key: 'italic', label: r.italic, icon: Italic, run: () => exec('italic') },
    { key: 'underline', label: r.underline, icon: Underline, run: () => exec('underline') },
    { key: 'heading', label: r.heading, icon: Heading2, run: toggleHeading },
    { key: 'bullet', label: r.bullet, icon: List, run: () => exec('insertUnorderedList') },
    { key: 'ordered', label: r.ordered, icon: ListOrdered, run: () => exec('insertOrderedList') },
    { key: 'link', label: r.link, icon: Link, run: openLink },
    { key: 'unlink', label: r.unlink, icon: Unlink, run: () => exec('unlink') },
    { key: 'clear', label: r.clear, icon: RemoveFormatting, run: clear },
  ];
  const pressed = (key: string): boolean | undefined =>
    key in fmt ? fmt[key as keyof typeof fmt] : undefined;
</script>

<div class="border-input flex min-w-0 flex-col overflow-hidden rounded-md border {className}">
  <div
    role="toolbar"
    aria-label={r.toolbar}
    aria-controls={id}
    class="bg-muted/50 border-input flex flex-wrap gap-0.5 border-b p-1"
  >
    {#each tools as tool (tool.key)}
      {@const Icon = tool.icon}
      <button
        type="button"
        class="hover:bg-accent focus-visible:ring-ring aria-pressed:bg-accent aria-pressed:text-foreground text-muted-foreground inline-flex size-11 items-center justify-center rounded-md focus-visible:ring-2 focus-visible:outline-none sm:size-8"
        aria-label={tool.label}
        title={tool.label}
        aria-pressed={pressed(tool.key)}
        onmousedown={(e) => e.preventDefault()}
        onclick={tool.run}><Icon size={16} aria-hidden="true" /></button
      >
    {/each}
  </div>
  {#if linkOpen}
    <div class="border-input flex flex-col gap-2 border-b p-2">
      <label for={`${id}-link`} class="text-sm font-medium">{r.linkUrl}</label>
      <div class="flex flex-wrap gap-2">
        <Input
          id={`${id}-link`}
          class="min-w-0 flex-1"
          bind:value={linkUrl}
          aria-invalid={linkError}
          aria-describedby={linkError ? `${id}-link-error` : undefined}
          onkeydown={(e) => {
            if (e.key === 'Enter') applyLink(e as unknown as MouseEvent);
            if (e.key === 'Escape') {
              e.preventDefault();
              linkOpen = false;
              restore();
            }
          }}
          autocomplete="off"
        />
        <Button type="button" size="sm" onclick={applyLink}>{r.linkApply}</Button>
        <Button
          type="button"
          size="sm"
          variant="outline"
          onclick={() => {
            linkOpen = false;
            restore();
          }}>{r.linkCancel}</Button
        >
      </div>
      {#if linkError}<p id={`${id}-link-error`} role="alert" class="text-destructive m-0 text-sm">
          {r.linkInvalid}
        </p>{/if}
    </div>
  {/if}
  <div
    bind:this={root}
    {id}
    role="textbox"
    tabindex="0"
    aria-multiline="true"
    aria-label={label}
    aria-describedby={describedby}
    contenteditable="true"
    spellcheck="true"
    class="mail-paper focus-visible:ring-ring min-h-40 bg-white px-4 py-3 text-[15px] leading-relaxed text-[#333333] focus-visible:ring-2 focus-visible:outline-none focus-visible:ring-inset"
    oninput={emit}
    {onpaste}
    ondrop={(e) => e.preventDefault()}
    onkeyup={refresh}
    onmouseup={refresh}
  ></div>
</div>

<style>
  .mail-paper {
    font-family: Arial, Helvetica, sans-serif;
  }
  .mail-paper :global(p) {
    margin: 0 0 0.75em;
  }
  .mail-paper :global(h2) {
    margin: 0.5em 0;
    font-size: 1.3em;
    font-weight: 700;
  }
  .mail-paper :global(h3) {
    margin: 0.5em 0;
    font-size: 1.1em;
    font-weight: 700;
  }
  .mail-paper :global(ul) {
    list-style: disc;
    padding-left: 1.5em;
    margin: 0 0 0.75em;
  }
  .mail-paper :global(ol) {
    list-style: decimal;
    padding-left: 1.5em;
    margin: 0 0 0.75em;
  }
  .mail-paper :global(a) {
    color: #1d4ed8;
    text-decoration: underline;
  }
</style>
