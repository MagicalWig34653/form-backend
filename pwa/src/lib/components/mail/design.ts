import { escapeAttr, isSafeImage, isSafeLink } from './richtext';

/**
 * Block model of the design editor. MJML is the stored source; this model is a lossless-enough view on it:
 * the content card is one `mj-section` with one `mj-column` holding simple blocks. Everything the editor does not
 * understand (other sections, multi-column layouts, mj-social, mj-head …) is kept verbatim as an "MJML" block, so a
 * mail built elsewhere (for example in the legacy GrapesJS editor) survives a round trip.
 */
export type BlockType = 'text' | 'button' | 'image' | 'divider' | 'spacer';
export interface SimpleBlock {
  id: string;
  type: BlockType;
  attrs: Record<string, string>;
  /** Inner markup: HTML of a text block, label of a button; empty for void blocks. */
  content: string;
}
export interface RawBlock {
  id: string;
  type: 'raw';
  /** MJML markup of the block. */
  mjml: string;
  /** Inside the content column (true) or directly in mj-body (false). */
  inColumn: boolean;
}
export type DesignBlock = SimpleBlock | RawBlock;
export interface DesignDoc {
  rootAttrs: Record<string, string>;
  head: string;
  bodyAttrs: Record<string, string>;
  sectionAttrs: Record<string, string>;
  blocks: DesignBlock[];
}

const TAG: Record<BlockType, string> = {
  text: 'mj-text',
  button: 'mj-button',
  image: 'mj-image',
  divider: 'mj-divider',
  spacer: 'mj-spacer',
};
const TYPE_OF: Record<string, BlockType> = Object.fromEntries(
  Object.entries(TAG).map(([k, v]) => [v, k as BlockType]),
);
const VOID = new Set<BlockType>(['image', 'divider', 'spacer']);
export const FONT = 'Arial, Helvetica, sans-serif';

let counter = 0;
export const blockId = (): string => `b${++counter}`;

export function newBlock(
  type: BlockType | 'raw',
  labels: { text: string; button: string },
): DesignBlock {
  const id = blockId();
  switch (type) {
    case 'text':
      return {
        id,
        type,
        attrs: { 'font-family': FONT, 'font-size': '15px', 'line-height': '1.6', color: '#333333' },
        content: `<p>${labels.text}</p>`,
      };
    case 'button':
      return {
        id,
        type,
        attrs: {
          href: 'https://',
          'background-color': '#2563eb',
          color: '#ffffff',
          'font-family': FONT,
          align: 'left',
        },
        content: labels.button,
      };
    case 'image':
      return { id, type, attrs: { src: '', alt: '' }, content: '' };
    case 'divider':
      return { id, type, attrs: { 'border-color': '#dddddd', 'border-width': '1px' }, content: '' };
    case 'spacer':
      return { id, type, attrs: { height: '24px' }, content: '' };
    case 'raw':
      return { id, type: 'raw', mjml: '<mj-text>MJML</mj-text>', inColumn: true };
  }
}

/** Starting point of a new design mail (same look as the legacy template). */
export function templateDoc(labels: { greeting: string }): DesignDoc {
  return {
    rootAttrs: {},
    head: '',
    bodyAttrs: { 'background-color': '#f4f4f4' },
    sectionAttrs: { 'background-color': '#ffffff', padding: '24px' },
    blocks: [
      {
        id: blockId(),
        type: 'text',
        attrs: { 'font-family': FONT, 'font-size': '15px', 'line-height': '1.6', color: '#333333' },
        content: labels.greeting,
      },
    ],
  };
}

/** A design whose only block carries the given rich text (used when switching from "Einfach" to "Design"). */
export function docFromRichText(html: string, labels: { greeting: string }): DesignDoc {
  const doc = templateDoc(labels);
  (doc.blocks[0] as SimpleBlock).content = html;
  return doc;
}

const attrsOf = (el: Element): Record<string, string> =>
  Object.fromEntries(Array.from(el.attributes).map((a) => [a.name, a.value]));

function sameAttrs(a: Record<string, string>, b: Record<string, string>): boolean {
  const ka = Object.keys(a);
  return ka.length === Object.keys(b).length && ka.every((k) => a[k] === b[k]);
}

/** MJML void tags are written self-closing; the HTML parser needs explicit end tags. */
const expandSelfClosing = (src: string): string =>
  src.replace(/<(mj-[a-z-]+)((?:\s+[^<>]*?)?)\s*\/>/gi, '<$1$2></$1>');

/** Parses MJML into the block model; null when there is no `mj-body`. Never executes or loads anything. */
export function parseMjml(src: string): DesignDoc | null {
  const template = document.createElement('template');
  template.innerHTML = expandSelfClosing(src);
  const root = template.content.querySelector('mjml');
  const body = root?.querySelector(':scope > mj-body');
  if (!root || !body) return null;
  const head = root.querySelector(':scope > mj-head');
  const doc: DesignDoc = {
    rootAttrs: attrsOf(root),
    head: head ? head.outerHTML : '',
    bodyAttrs: attrsOf(body),
    sectionAttrs: {},
    blocks: [],
  };
  let haveSection = false;
  for (const child of Array.from(body.children)) {
    const column = child.localName === 'mj-section' ? child.children : null;
    const col = column && column.length === 1 ? column[0]! : null;
    const editable =
      col !== null &&
      col.localName === 'mj-column' &&
      col.attributes.length === 0 &&
      (!haveSection ? true : sameAttrs(attrsOf(child), doc.sectionAttrs));
    if (!editable || !col) {
      doc.blocks.push({ id: blockId(), type: 'raw', mjml: child.outerHTML, inColumn: false });
      continue;
    }
    if (!haveSection) {
      doc.sectionAttrs = attrsOf(child);
      haveSection = true;
    }
    for (const el of Array.from(col.children)) {
      const type = TYPE_OF[el.localName];
      if (type) {
        doc.blocks.push({
          id: blockId(),
          type,
          attrs: attrsOf(el),
          content: VOID.has(type) ? '' : el.innerHTML,
        });
      } else {
        doc.blocks.push({ id: blockId(), type: 'raw', mjml: el.outerHTML, inColumn: true });
      }
    }
  }
  if (!haveSection) doc.sectionAttrs = { 'background-color': '#ffffff', padding: '24px' };
  return doc;
}

/** Attributes whose value is a URL; unsafe values are left out of the output instead of being sent. */
function safeAttrs(type: BlockType, attrs: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'href' && !isSafeLink(v)) continue;
    if (k === 'src' && type === 'image' && !isSafeImage(v)) continue;
    if (/^on/i.test(k)) continue;
    out[k] = v;
  }
  return out;
}

const attrString = (attrs: Record<string, string>): string =>
  Object.entries(attrs)
    .filter(([k]) => /^[a-z][a-z0-9-]*$/i.test(k))
    .map(([k, v]) => ` ${k}="${escapeAttr(v)}"`)
    .join('');

function blockMjml(b: SimpleBlock): string {
  const tag = TAG[b.type];
  const attrs = attrString(safeAttrs(b.type, b.attrs));
  return VOID.has(b.type) ? `<${tag}${attrs} />` : `<${tag}${attrs}>${b.content}</${tag}>`;
}

export function serializeMjml(doc: DesignDoc): string {
  let body = '';
  let run = '';
  const flush = (): void => {
    if (run === '') return;
    body += `<mj-section${attrString(doc.sectionAttrs)}><mj-column>${run}</mj-column></mj-section>`;
    run = '';
  };
  for (const b of doc.blocks) {
    if (b.type === 'raw') {
      if (b.inColumn) run += b.mjml;
      else {
        flush();
        body += b.mjml;
      }
    } else run += blockMjml(b);
  }
  flush();
  return `<mjml${attrString(doc.rootAttrs)}>${doc.head}<mj-body${attrString(doc.bodyAttrs)}>${body}</mj-body></mjml>`;
}

/** Problems that keep a block's value out of the mail (shown next to the field). */
export function blockProblems(b: DesignBlock): { href?: boolean; src?: boolean } {
  if (b.type === 'raw') return {};
  const p: { href?: boolean; src?: boolean } = {};
  if (b.attrs.href !== undefined && b.attrs.href !== '' && !isSafeLink(b.attrs.href)) p.href = true;
  if (b.type === 'button' && !isSafeLink(b.attrs.href ?? '')) p.href = true;
  if (b.type === 'image' && !isSafeImage(b.attrs.src ?? '')) p.src = true;
  return p;
}

/** Rich text of the design for "Einfach": text blocks as they are, buttons as links. */
export function designToRichText(doc: DesignDoc): string {
  return doc.blocks
    .map((b) => {
      if (b.type === 'text') return b.content;
      if (b.type === 'button')
        return isSafeLink(b.attrs.href ?? '')
          ? `<p><a href="${escapeAttr(b.attrs.href!)}">${b.content}</a></p>`
          : `<p>${b.content}</p>`;
      return '';
    })
    .join('');
}

/** Moves the block at `from` to index `to` (in the final list). */
export function moveBlock<T>(list: T[], from: number, to: number): T[] {
  if (from === to || from < 0 || from >= list.length) return list;
  const next = [...list];
  const [item] = next.splice(from, 1);
  next.splice(Math.max(0, Math.min(to, next.length)), 0, item!);
  return next;
}
