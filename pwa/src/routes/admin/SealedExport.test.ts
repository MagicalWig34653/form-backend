import { beforeEach, expect, it, vi } from 'vitest';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import SealedExport from './SealedExport.svelte';
const mock = vi.hoisted(() => ({
  exportPage: vi.fn(),
  lock: undefined as (() => void) | undefined,
}));
vi.mock('$lib/api', () => ({ adminApi: mock }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: {
    onLock: (fn: () => void) => {
      mock.lock = fn;
      return () => {};
    },
  },
}));
const item = { id: 'synthetic', package: 'sealed', attachments: 0 };
beforeEach(() => {
  vi.resetAllMocks();
  URL.createObjectURL = vi.fn(() => 'blob:synthetic');
  URL.revokeObjectURL = vi.fn();
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
});
async function start() {
  await fireEvent.click(screen.getByRole('button', { name: 'Verschlüsselt exportieren' }));
  await fireEvent.click(await screen.findByRole('button', { name: 'Exportieren' }));
}
it('downloads all ciphertext pages together without requiring an unlocked data key', async () => {
  mock.exportPage.mockResolvedValueOnce({ ok: true, data: { items: [item], nextCursor: 'next' } });
  mock.exportPage.mockResolvedValueOnce({
    ok: true,
    data: { items: [{ ...item, id: 'second' }], nextCursor: null },
  });
  render(SealedExport, { tenant: 't', form: 'f' });
  await start();
  await waitFor(() => expect(URL.createObjectURL).toHaveBeenCalledOnce());
  expect(mock.exportPage.mock.calls).toEqual([
    ['t', 'f', undefined],
    ['t', 'f', 'next'],
  ]);
  const blob = vi.mocked(URL.createObjectURL).mock.calls[0]![0] as Blob;
  expect(JSON.parse(await blob.text())).toEqual([item, { ...item, id: 'second' }]);
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:synthetic');
});
for (const stop of ['cancel', 'lock', 'unmount', 'error'] as const) {
  it(`never downloads a partial file after ${stop}`, async () => {
    let resolve!: (value: unknown) => void;
    mock.exportPage.mockResolvedValueOnce({
      ok: true,
      data: { items: [item], nextCursor: 'next' },
    });
    mock.exportPage.mockReturnValueOnce(
      new Promise((r) => {
        resolve = r;
      }),
    );
    const view = render(SealedExport, { tenant: 't', form: 'f' });
    await start();
    await screen.findByText('1 Einsendungen vorbereitet. Der Export läuft …');
    if (stop === 'cancel') await fireEvent.click(screen.getByRole('button', { name: 'Abbrechen' }));
    if (stop === 'lock') mock.lock!();
    if (stop === 'unmount') view.unmount();
    resolve(
      stop === 'error'
        ? { ok: false, error: { kind: 'http', status: 503 } }
        : { ok: true, data: { items: [], nextCursor: null } },
    );
    await Promise.resolve();
    await Promise.resolve();
    expect(URL.createObjectURL).not.toHaveBeenCalled();
  });
}
