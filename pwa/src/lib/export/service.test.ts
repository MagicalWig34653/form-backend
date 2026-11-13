import { beforeEach, expect, it, vi } from 'vitest';
import { KeyOperation } from '$lib/crypto/operation';
const mock = vi.hoisted(() => ({
  entries: vi.fn(),
  ciphertext: vi.fn(),
  request: vi.fn(),
  key: vi.fn(),
  open: vi.fn(),
}));
vi.mock('$lib/api', () => ({ adminApi: mock, http: mock }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: { operation: () => new KeyOperation(), onLock: () => () => {}, dataKey: mock.key },
}));
vi.mock('$lib/crypto/packageV2', () => ({ openPackage: mock.open }));
import { scan, audit } from './service';
const filters = { query: 'Person', from: '', until: '' };
beforeEach(() => {
  vi.resetAllMocks();
  mock.request.mockResolvedValue({ ok: true, data: { canExport: true, canDelete: true } });
  mock.key.mockReturnValue(new Uint8Array(32));
  mock.ciphertext.mockResolvedValue({ ok: true, data: { keyId: 'k', package: 'sealed' } });
});
it('paginates, wipes plaintext buffers and preserves failures as markers', async () => {
  mock.entries
    .mockResolvedValueOnce({
      ok: true,
      data: { items: [{ id: 'a', receivedAt: null }], nextCursor: 'c' },
    })
    .mockResolvedValueOnce({
      ok: true,
      data: { items: [{ id: 'b', receivedAt: null }], nextCursor: null },
    });
  const bytes = new TextEncoder().encode('{"fields":{"name":"Person"}}');
  mock.open.mockResolvedValueOnce(bytes).mockRejectedValueOnce(new Error());
  const rows = await scan(
    't',
    'f',
    filters,
    () => {},
    () => {},
  );
  expect(rows.map((r) => r.unreadable)).toEqual([false, true]);
  expect(bytes.every((b) => b === 0)).toBe(true);
  expect(mock.entries).toHaveBeenLastCalledWith('t', 'f', 'c');
  expect(JSON.stringify(mock.request.mock.calls)).not.toContain('Person');
});
it('aborts on permission revocation instead of converting it into a content marker', async () => {
  mock.entries.mockResolvedValue({
    ok: true,
    data: { items: [{ id: 'a', receivedAt: null }], nextCursor: null },
  });
  mock.ciphertext.mockResolvedValue({ ok: false, error: { kind: 'http', status: 403 } });
  await expect(
    scan(
      't',
      'f',
      filters,
      () => {},
      () => {},
    ),
  ).rejects.toThrow();
  expect(mock.open).not.toHaveBeenCalled();
});
it('does not decrypt or publish when cancelled during an await', async () => {
  mock.entries.mockResolvedValue({ ok: true, data: { items: [], nextCursor: null } });
  await expect(
    scan(
      't',
      'f',
      filters,
      () => {
        throw new Error('cancel');
      },
      () => {},
    ),
  ).rejects.toThrow('cancel');
  expect(mock.entries).not.toHaveBeenCalled();
});
it('audits without person data and propagates failure to block download', async () => {
  await audit('t', 'f');
  expect(mock.request).toHaveBeenCalledWith('POST', '/tenants/t/forms/f/export/audit', {
    body: {},
  });
  mock.request.mockResolvedValue({ ok: false, error: { kind: 'http', status: 403 } });
  await expect(audit('t', 'f')).rejects.toThrow();
});
it('includes a missing-key row as a marker without attempting decryption', async () => {
  mock.entries.mockResolvedValue({
    ok: true,
    data: { items: [{ id: 'no-key', receivedAt: null }], nextCursor: null },
  });
  mock.key.mockReturnValue(undefined);
  expect(
    await scan(
      't',
      'f',
      filters,
      () => {},
      () => {},
    ),
  ).toEqual([{ id: 'no-key', receivedAt: null, fields: {}, unreadable: true }]);
  expect(mock.open).not.toHaveBeenCalled();
});
it('discards the complete scan when the final live rights check fails', async () => {
  mock.entries.mockResolvedValue({
    ok: true,
    data: { items: [{ id: 'a', receivedAt: null }], nextCursor: null },
  });
  mock.open.mockResolvedValue(new TextEncoder().encode('{"fields":{"name":"Person"}}'));
  mock.request
    .mockResolvedValueOnce({ ok: true, data: {} })
    .mockResolvedValueOnce({ ok: false, error: { kind: 'http', status: 403 } });
  await expect(
    scan(
      't',
      'f',
      filters,
      () => {},
      () => {},
    ),
  ).rejects.toThrow();
});
