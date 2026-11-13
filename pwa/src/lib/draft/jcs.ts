/** RFC 8785 canonical JSON for the subset the server accepts (ADR 0008 F1): whole numbers within ±(2^53−1), no floats, no
 * duplicate keys (impossible in a JS object). Keys sort by UTF-16 code units, which is JavaScript's default string order. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

export function canonicalize(value: unknown): string {
  if (value === null) return 'null';
  switch (typeof value) {
    case 'boolean':
      return value ? 'true' : 'false';
    case 'number':
      if (!Number.isSafeInteger(value))
        throw new Error('only whole numbers within ±(2^53−1) are allowed');
      return String(value);
    case 'string':
      return JSON.stringify(value);
    case 'object': {
      if (Array.isArray(value)) return '[' + value.map(canonicalize).join(',') + ']';
      const o = value as Record<string, unknown>;
      return (
        '{' +
        Object.keys(o)
          .filter((k) => o[k] !== undefined)
          .sort()
          .map((k) => JSON.stringify(k) + ':' + canonicalize(o[k]))
          .join(',') +
        '}'
      );
    }
    default:
      throw new Error('unsupported value');
  }
}

/** Lower-case hex SHA-256 of the canonical form: the one hash used for drafts, versions and manifests. */
export async function sha256Hex(value: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(canonicalize(value));
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}
