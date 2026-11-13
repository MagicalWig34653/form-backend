import { escapeText } from './richtext';
import { stripMarker } from './source';

/** Extra restrictions for the preview document (they add to the app's own policy, never loosen it). */
const PREVIEW_CSP =
  "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; font-src 'none'; form-action 'none'";

/** Example value shown for a placeholder in the preview. */
export const exampleValue = (name: string, prefix: string): string => `${prefix} ${name}`;

/**
 * Document for the sandboxed preview frame: marker removed, placeholders replaced by escaped example values (as the
 * server escapes real values in HTML mails), and a meta policy that blocks scripts, forms and remote fonts.
 */
export function previewDocument(body: string, prefix: string): string {
  const html = stripMarker(body).replace(/#=\[(\w+)\]=#/g, (_, name: string) =>
    escapeText(exampleValue(name, prefix)),
  );
  const meta = `<meta http-equiv="Content-Security-Policy" content="${PREVIEW_CSP}">`;
  return /<head[^>]*>/i.test(html)
    ? html.replace(/<head[^>]*>/i, (m) => m + meta)
    : `<!doctype html><html><head>${meta}<meta charset="utf-8"></head><body>${html}</body></html>`;
}
