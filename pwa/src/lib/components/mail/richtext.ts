/**
 * Whitelist sanitizer for the rich-text editors ("Einfach" and the design text block). Input is parsed inert (in a
 * <template>, nothing loads or runs), the output is rebuilt from scratch: only a few mail-safe tags survive, links only
 * with http(s) or mailto, every other element is unwrapped (its text stays) and dangerous containers are dropped.
 */

const KEEP: Record<string, string> = {
  p: 'p',
  div: 'p',
  br: 'br',
  strong: 'strong',
  b: 'strong',
  em: 'em',
  i: 'em',
  u: 'u',
  h1: 'h2',
  h2: 'h2',
  h3: 'h3',
  ul: 'ul',
  ol: 'ol',
  li: 'li',
  a: 'a',
};
const DROP = new Set([
  'script',
  'style',
  'template',
  'iframe',
  'object',
  'embed',
  'noscript',
  'svg',
  'math',
  'head',
  'title',
  'meta',
  'link',
  'textarea',
  'select',
  'button',
  'input',
]);
const BLOCK = new Set(['p', 'h2', 'h3', 'ul', 'ol', 'li']);

/** Link targets allowed in mails: http(s) and mailto, written literally (a placeholder may follow, never lead). */
export function isSafeLink(url: string): boolean {
  return /^(https?:\/\/[^\s"'<>]+|mailto:[^\s"'<>]+)$/i.test(url.trim());
}

/** Image sources: https URLs or small inline data images. */
export function isSafeImage(url: string): boolean {
  const v = url.trim();
  return (
    /^https:\/\/[^\s"'<>]+$/i.test(v) ||
    /^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$/i.test(v)
  );
}

export const escapeText = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
export const escapeAttr = (s: string): string =>
  s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Serializes sanitized children of a DOM node (works on a live contenteditable or an inert template). */
export function serializeClean(node: Node): string {
  let out = '';
  node.childNodes.forEach((child) => {
    if (child.nodeType === 3) {
      out += escapeText(child.textContent ?? '');
      return;
    }
    if (child.nodeType !== 1) return;
    const el = child as Element;
    const name = el.localName;
    if (DROP.has(name)) return;
    const tag = KEEP[name];
    if (!tag) {
      out += serializeClean(el);
      return;
    }
    if (tag === 'br') {
      out += '<br>';
      return;
    }
    const inner = serializeClean(el);
    if (tag === 'a') {
      const href = el.getAttribute('href') ?? '';
      out += isSafeLink(href) ? `<a href="${escapeAttr(href.trim())}">${inner}</a>` : inner;
      return;
    }
    // Drop empty inline wrappers; keep empty paragraphs as a line (browsers render them with <br>).
    if (inner === '' && !BLOCK.has(tag)) return;
    out += `<${tag}>${inner}</${tag}>`;
  });
  return out;
}

/** Parses untrusted HTML inert and returns the sanitized markup. */
export function sanitizeRichText(html: string): string {
  const template = document.createElement('template');
  template.innerHTML = html;
  return serializeClean(template.content);
}

/** Sanitized nodes for a contenteditable (never assigns untrusted markup to a live element). */
export function sanitizedFragment(html: string): DocumentFragment {
  const template = document.createElement('template');
  template.innerHTML = sanitizeRichText(html);
  return template.content;
}

/** Plain text of markup (parsed inert). */
export function textOf(html: string): string {
  const template = document.createElement('template');
  template.innerHTML = html;
  return template.content.textContent ?? '';
}

/** True when the sanitized HTML has no visible text. */
export function isBlankRichText(html: string): boolean {
  return html.replace(/<[^>]*>/g, '').replace(/&nbsp;|\s/g, '') === '';
}

/** Rich text in a plain, mail-safe frame (table layout, inline styles only). */
export function simpleFrame(inner: string): string {
  return (
    '<!doctype html><html><head><meta charset="utf-8">' +
    '<meta name="viewport" content="width=device-width, initial-scale=1"></head>' +
    '<body style="margin:0;padding:0;background-color:#f4f4f4;">' +
    '<table border="0" cellpadding="0" cellspacing="0" role="presentation" width="100%" ' +
    'style="width:100%;background-color:#f4f4f4;margin:0;padding:0;">' +
    '<tr><td align="center" style="padding:24px 12px;">' +
    '<table border="0" cellpadding="0" cellspacing="0" role="presentation" width="600" ' +
    'style="width:600px;max-width:100%;background-color:#ffffff;border-radius:6px;">' +
    '<tr><td style="padding:24px;font-family:Arial,Helvetica,sans-serif;font-size:15px;' +
    'line-height:1.6;color:#333333;">' +
    inner +
    '</td></tr></table></td></tr></table></body></html>'
  );
}
