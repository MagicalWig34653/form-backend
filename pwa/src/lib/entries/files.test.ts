// SPDX-License-Identifier: AGPL-3.0-only
import { describe, expect, it } from 'vitest';
import { leaves, safeFileName } from './files';

const f = (n: string) => ({ name: n, size: 1, sha256: n });

describe('attachment order', () => {
  it('numbers numeric field names bytewise like the server (10 before 2)', () => {
    const parsed = JSON.parse(
      '{"10":' + JSON.stringify(f('ten')) + ',"2":' + JSON.stringify(f('two')) + '}',
    );
    expect(Object.keys(parsed)).toEqual(['2', '10']); // what the engine enumerates
    expect(leaves(parsed).map((x) => x.name)).toEqual(['ten', 'two']);
  });
  it('keeps list order inside a field and sorts non-ASCII by UTF-8 bytes', () => {
    const v = { ä: [f('a1'), f('a2')], z: f('z'), '𝒳': f('x') };
    expect(leaves(v).map((x) => x.name)).toEqual(['z', 'a1', 'a2', 'x']);
  });
});

describe('download name', () => {
  it('neutralises bidi overrides and path characters', () => {
    expect(safeFileName('re‮fdp.exe')).toBe('re_fdp.exe');
    expect(safeFileName('a/b\\c.pdf')).toBe('a_b_c.pdf');
  });
});
