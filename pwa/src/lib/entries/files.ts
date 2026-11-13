// SPDX-License-Identifier: AGPL-3.0-only
const utf8 = new TextEncoder();

/** Bytewise UTF-8 order, the order the server signs and numbers attachments in (JS would enumerate "2" before "10"). */
export function byteOrder(a: string, b: string): number {
  const x = utf8.encode(a);
  const y = utf8.encode(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++)
    if (x[i] !== y[i]) return (x[i] ?? 0) - (y[i] ?? 0);
  return x.length - y.length;
}

export interface FileMeta {
  name: string;
  size: number;
  sha256: string;
}

/** File metadata in signed order (= attachment ordinal): keys sorted bytewise, lists in order. */
export function leaves(value: unknown): FileMeta[] {
  if (Array.isArray(value)) return value.flatMap(leaves);
  if (value && typeof value === 'object') {
    const o = value as Record<string, unknown>;
    if (typeof o.sha256 === 'string' && typeof o.name === 'string')
      return [{ name: o.name, size: Number(o.size) || 0, sha256: o.sha256 }];
    return Object.keys(o)
      .sort(byteOrder)
      .flatMap((k) => leaves(o[k]));
  }
  return [];
}

/** Download file name: no path characters, control characters or bidirectional overrides (they fake the extension). */
export function safeFileName(name: string): string {
  return [...name]
    .map((c) =>
      c.charCodeAt(0) < 32 || '\\/:*?"<>|'.includes(c) || /[؜‎‏‪-‮⁦-⁩]/.test(c) ? '_' : c,
    )
    .join('');
}
