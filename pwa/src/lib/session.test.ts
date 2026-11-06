import { afterEach, expect, it, vi } from 'vitest';

const api = vi.hoisted(() => ({
  auth: { session: vi.fn(), logout: vi.fn() },
  admin: { me: vi.fn(), tenants: vi.fn() },
}));
vi.mock('./api', () => ({ authApi: api.auth, adminApi: api.admin }));
vi.mock('./crypto/automation.svelte', () => ({
  accessAutomation: { start: vi.fn(), stop: vi.fn() },
}));

class TestChannel {
  static peers: TestChannel[] = [];
  onmessage: ((event: { data: unknown }) => void) | null = null;
  constructor(public name: string) {
    TestChannel.peers.push(this);
  }
  postMessage(data: unknown) {
    for (const peer of TestChannel.peers) {
      if (peer !== this && peer.name === this.name) peer.onmessage?.({ data });
    }
  }
}
vi.stubGlobal('BroadcastChannel', TestChannel);
const { session } = await import('./session.svelte');
const { keyring } = await import('./crypto/keyring.svelte');
function identity(id = 'a', token = 'session-1') {
  api.auth.session.mockResolvedValue({
    ok: true,
    data: { state: 'authenticated', subjectId: id, csrfToken: token },
  });
  api.admin.me.mockResolvedValue({ ok: true, data: { id } });
  api.admin.tenants.mockResolvedValue({ ok: true, data: { items: [] } });
}
afterEach(() => {
  session.expired(false);
  vi.clearAllMocks();
});

it('keeps keys for the same identity, wipes buffers on account or session change', async () => {
  identity();
  await session.load();
  const secret = new Uint8Array(32).fill(7);
  keyring.adopt('kid', secret);
  await session.load();
  expect(keyring.dataKey('kid')).toBe(secret);
  identity('b');
  await session.load();
  expect(secret.every((b) => b === 0)).toBe(true);
  const next = new Uint8Array(32).fill(9);
  keyring.adopt('kid', next);
  identity('b', 'session-2');
  await session.load();
  expect(next.every((b) => b === 0)).toBe(true);
  expect(keyring.kids).toEqual([]);
});
it('second channel locks locally without echo and cancels a pending load', async () => {
  identity();
  await session.load();
  const secret = new Uint8Array(32).fill(7);
  keyring.adopt('kid', secret);
  let release!: (value: unknown) => void;
  api.admin.me.mockReturnValueOnce(
    new Promise((r) => {
      release = r;
    }),
  );
  const pending = session.load();
  await vi.waitFor(() => expect(release).toBeDefined());
  const peer = new TestChannel('form-auth-invalidate');
  const listener = vi.fn();
  peer.onmessage = listener;
  peer.postMessage('invalidate');
  release({ ok: true, data: { id: 'a' } });
  await pending;
  expect(secret.every((b) => b === 0)).toBe(true);
  expect(session.me).toBeNull();
  expect(session.status).toBe('anonymous');
  expect(listener).not.toHaveBeenCalled();
});
it('storage fallback locks and logout broadcasts before the HTTP request resolves', async () => {
  identity();
  await session.load();
  const secret = new Uint8Array(32).fill(7);
  keyring.adopt('kid', secret);
  window.dispatchEvent(
    new StorageEvent('storage', { key: 'form-auth-invalidate', newValue: 'nonce' }),
  );
  expect(secret.every((b) => b === 0)).toBe(true);
  const peer = new TestChannel('form-auth-invalidate');
  const listener = vi.fn();
  peer.onmessage = listener;
  api.auth.logout.mockResolvedValue({ ok: true });
  await session.logout();
  expect(listener).toHaveBeenCalledWith({ data: 'invalidate' });
});
