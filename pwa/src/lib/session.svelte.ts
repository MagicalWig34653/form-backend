import { accessAutomation } from './crypto/automation.svelte';
import { keyring } from './crypto/keyring.svelte';
import { adminApi, authApi } from './api';
import type { Me, Tenant } from './api/admin';
import type { ApiError } from './api/client';

const channelName = 'form-auth-invalidate';
const channel = typeof BroadcastChannel !== 'undefined' ? new BroadcastChannel(channelName) : null;
let generation = 0;
function publish(): void {
  channel?.postMessage('invalidate');
  try {
    localStorage.setItem(channelName, crypto.randomUUID());
  } catch {
    /* Storage may be disabled; BroadcastChannel still works. */
  }
}

type Status = 'loading' | 'anonymous' | 'ready' | 'error';
const state = $state<{ status: Status; me: Me | null; tenants: Tenant[]; error: ApiError | null }>({
  status: 'loading',
  me: null,
  tenants: [],
  error: null,
});

/** Who is signed in and which customers they can see. Memory only; the cookie session is the truth. */
export const session = {
  get status() {
    return state.status;
  },
  get me() {
    return state.me;
  },
  get tenants() {
    return state.tenants;
  },
  get error() {
    return state.error;
  },
  async load(): Promise<void> {
    const run = ++generation;
    state.status = 'loading';
    const s = await authApi.session();
    if (run !== generation) return;
    if (!s.ok) {
      if (s.error.status === 401) this.expired();
      state.error = s.error;
      state.status = s.error.kind === 'http' && s.error.status === 401 ? 'anonymous' : 'error';
      return;
    }
    if (s.data.state !== 'authenticated') {
      this.expired();
      return;
    }
    // Invalidate before fetching any account-scoped data or resuming automation.
    const changed = keyring.bind(s.data.subjectId ?? null, s.data.csrfToken);
    if (changed) {
      accessAutomation.stop();
      state.me = null;
      state.tenants = [];
      publish();
    }
    const [me, tenants] = await Promise.all([adminApi.me(), adminApi.tenants()]);
    if (run !== generation) return;
    if (!me.ok || !tenants.ok) {
      const e = (!me.ok ? me : (tenants as { ok: false; error: ApiError })).error;
      if (e.status === 401) this.expired();
      state.error = e;
      state.status = e.status === 401 ? 'anonymous' : 'error';
      return;
    }
    if (s.data.subjectId && me.data.id !== s.data.subjectId) {
      this.expired();
      return;
    }
    keyring.bind(me.data.id, s.data.csrfToken);
    state.me = me.data;
    state.tenants = tenants.data.items;
    state.error = null;
    state.status = 'ready';
    accessAutomation.start(state.tenants.map((t) => t.id));
  },
  async refreshTenants(): Promise<void> {
    const run = generation;
    const r = await adminApi.tenants();
    if (run !== generation || state.status !== 'ready') return;
    if (r.ok) {
      state.tenants = r.data.items;
      accessAutomation.start(state.tenants.map((t) => t.id));
    }
  },
  async logout(): Promise<void> {
    // End the server session first: the login page reads the session state as soon as it mounts and would otherwise
    // still see "authenticated" (stale "Sie sind angemeldet" screen after logging out).
    try {
      await authApi.logout();
    } finally {
      this.expired();
    }
  },
  /** A call answered 401 or another tab changed the cookie session. */
  expired(broadcast = true): void {
    generation++;
    accessAutomation.stop();
    keyring.lock();
    keyring.bind(null, null);
    state.me = null;
    state.tenants = [];
    state.status = 'anonymous';
    if (broadcast) publish();
  },
};
if (channel)
  channel.onmessage = (event) => {
    if (event.data === 'invalidate') session.expired(false);
  };
if (typeof window !== 'undefined') {
  window.addEventListener('storage', (event) => {
    if (event.key === channelName && event.newValue) session.expired(false);
  });
}
