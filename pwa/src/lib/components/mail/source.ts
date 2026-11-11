/**
 * Storage format of a built HTML mail (same as the legacy mail editor, so imported mails stay editable):
 *
 *   <!--kubus-mail-quelle:BASE64(JSON {m, s, q})-->\n<sent html>
 *
 * m = editor the source belongs to ("design" = MJML, "einfach" = rich-text HTML), s = editable source,
 * q = true when the HTML was edited by hand afterwards (the next start then opens the source view instead of
 * regenerating from the old source). The body stays plain HTML for the server: the comment is sent as well and is
 * harmless; placeholders inside the base64 text never match `#=[name]=#`.
 */
export const MARKER = 'kubus-mail-quelle:';

/** Builder modes; "simple" is stored as "einfach" for compatibility. */
export type BuilderMode = 'design' | 'simple' | 'source';
export type SourceKind = 'design' | 'simple';

export interface MarkerState {
  kind: SourceKind;
  source: string;
  /** The HTML was edited by hand after the source was generated. */
  handEdited: boolean;
}

const MARKER_RE = /<!--\s*kubus-mail-quelle:([A-Za-z0-9+/=]+)\s*-->/;
const MARKER_STRIP_RE = /<!--\s*kubus-mail-quelle:[A-Za-z0-9+/=]+\s*-->\s*/;

/** UTF-8 base64 (identical bytes to the legacy `btoa(unescape(encodeURIComponent(text)))`). */
export function encodeBase64(text: string): string {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  }
  return btoa(binary);
}

export function decodeBase64(base64: string): string {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
}

export function buildMarker(kind: SourceKind, source: string, handEdited = false): string {
  const json = JSON.stringify({
    m: kind === 'simple' ? 'einfach' : 'design',
    s: source,
    q: handEdited,
  });
  return `<!--${MARKER}${encodeBase64(json)}-->`;
}

/** Reads the marker; null when there is none or it is unreadable (the editor then starts in the source view). */
export function readMarker(body: string): MarkerState | null {
  const hit = MARKER_RE.exec(body ?? '');
  if (!hit) return null;
  try {
    const parsed: unknown = JSON.parse(decodeBase64(hit[1]!));
    if (!parsed || typeof parsed !== 'object') return null;
    const { m, s, q } = parsed as { m?: unknown; s?: unknown; q?: unknown };
    if (typeof s !== 'string' || (m !== 'design' && m !== 'einfach')) return null;
    return { kind: m === 'design' ? 'design' : 'simple', source: s, handEdited: q === true };
  } catch {
    return null;
  }
}

/** The sent HTML without the marker comment. */
export function stripMarker(body: string): string {
  return String(body ?? '').replace(MARKER_STRIP_RE, '');
}

/** Complete body: marker, line break, HTML. */
export function composeBody(marker: MarkerState | null, html: string): string {
  return marker ? `${buildMarker(marker.kind, marker.source, marker.handEdited)}\n${html}` : html;
}

/** Mode the editor opens in for a stored body. */
export function initialMode(body: string): BuilderMode {
  const m = readMarker(body);
  if (!m) return 'source';
  return m.handEdited ? 'source' : m.kind;
}

/** UTF-8 size in bytes (the server limits a template body to 100 000 bytes). */
export const byteLength = (text: string): number => new TextEncoder().encode(text).length;
export const MAX_BODY_BYTES = 100_000;
