import { beforeEach, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';
import Export from './Export.svelte';
const mock = vi.hoisted(() => ({ audit: vi.fn(), lock: undefined as (() => void) | undefined }));
vi.mock('$lib/export/service', () => ({ audit: mock.audit }));
vi.mock('$lib/crypto/keyring.svelte', () => ({
  keyring: {
    onLock: (fn: () => void) => {
      mock.lock = fn;
      return () => {};
    },
  },
}));
const rows = [{ id: 'a', receivedAt: null, fields: { name: 'synthetic' }, unreadable: false }];
beforeEach(() => {
  vi.resetAllMocks();
  URL.createObjectURL = vi.fn(() => 'blob:synthetic');
  URL.revokeObjectURL = vi.fn();
  vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {});
});
it('does not create a download when audit or live authorization fails', async () => {
  const failure = vi.fn().mockResolvedValue(undefined);
  mock.audit.mockRejectedValue(new Error());
  render(Export, {
    tenant: 't',
    form: 'f',
    rows,
    allowed: true,
    disabled: false,
    onFailure: failure,
  });
  await fireEvent.click(screen.getByText('Auswahl als CSV'));
  expect(failure).toHaveBeenCalled();
  expect(URL.createObjectURL).not.toHaveBeenCalled();
});
it('discards an audit response arriving after lock', async () => {
  let resolve!: () => void;
  mock.audit.mockReturnValue(new Promise<void>((r) => (resolve = r)));
  render(Export, {
    tenant: 't',
    form: 'f',
    rows,
    allowed: true,
    disabled: false,
    onFailure: vi.fn(),
  });
  await fireEvent.click(screen.getByText('Auswahl als JSON'));
  mock.lock!();
  resolve();
  await Promise.resolve();
  await Promise.resolve();
  expect(URL.createObjectURL).not.toHaveBeenCalled();
});
it('downloads only after auditing and revokes the object URL', async () => {
  mock.audit.mockResolvedValue(undefined);
  render(Export, {
    tenant: 't',
    form: 'f',
    rows,
    allowed: true,
    disabled: false,
    onFailure: vi.fn(),
  });
  await fireEvent.click(screen.getByText('Auswahl als CSV'));
  expect(mock.audit).toHaveBeenCalledWith('t', 'f');
  expect(URL.createObjectURL).toHaveBeenCalled();
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:synthetic');
});
